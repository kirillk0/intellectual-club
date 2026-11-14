defmodule IntellectualClub.Files.ImageVerdicts do
  @moduledoc """
  Structural image verdicts remembered by payload SHA-256.

  A verdict is computed once per content and rule set by
  `IntellectualClub.ImageProcessor.validate/1` and reused until
  `ImageProcessor.check_version/0` changes. Callers must verify that a payload
  matches its stored size and SHA-256 before trusting or recording a verdict for
  it; a verdict says nothing about whether a particular stored blob is intact.

  Lookups take and return a memo (`sha256 => verdict | nil`) so that one request
  preparation or hydration issues at most one query per batch of known hashes
  plus one per hash that becomes known later. `nil` memoizes a missing row.

  What a model provider did with an image is not a property of the bytes; it is
  recorded per LLM configuration by `IntellectualClub.Files.ImageProviderVerdicts`.
  """

  require Ash.Query

  alias IntellectualClub.Files.ImageVerdict
  alias IntellectualClub.ImageProcessor

  @max_reason_length 200

  @type memo :: %{optional(String.t()) => ImageVerdict.t() | nil}
  @type classification :: :valid | :invalid | :unchecked

  @doc """
  Loads the verdicts for all `sha256s` that are not yet in `memo` with a single
  query. Hashes without a row are memoized as `nil`; malformed hashes are ignored.
  """
  @spec load([String.t()], memo()) :: {:ok, memo()} | {:error, term()}
  def load(sha256s, memo \\ %{}) when is_list(sha256s) and is_map(memo) do
    missing =
      sha256s
      |> Enum.filter(&sha256?/1)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(memo, &1))

    if missing == [] do
      {:ok, memo}
    else
      ImageVerdict
      |> Ash.Query.filter(sha256 in ^missing)
      |> Ash.read(authorize?: false)
      |> case do
        {:ok, verdicts} ->
          found = Map.new(verdicts, &{&1.sha256, &1})
          {:ok, Enum.reduce(missing, memo, &Map.put(&2, &1, Map.get(found, &1)))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Returns the remembered verdict for one hash (or `nil`), using and updating `memo`."
  @spec fetch(String.t(), memo()) :: {:ok, ImageVerdict.t() | nil, memo()} | {:error, term()}
  def fetch(sha256, memo) when is_binary(sha256) and is_map(memo) do
    with {:ok, memo} <- load([sha256], memo), do: {:ok, Map.get(memo, sha256), memo}
  end

  @doc """
  Returns a verdict produced by the current rules for `payload`, computing and
  upserting it when it is missing or stale.

  `file` supplies the stored `sha256` and `size_bytes`; the caller must already
  have verified that `payload` matches both.
  """
  @spec ensure(%{sha256: String.t(), size_bytes: non_neg_integer()}, binary(), memo()) ::
          {:ok, ImageVerdict.t(), memo()} | {:error, term()}
  def ensure(%{sha256: sha256, size_bytes: size_bytes}, payload, memo)
      when is_binary(sha256) and is_binary(payload) and byte_size(payload) == size_bytes and
             is_map(memo) do
    with {:ok, verdict, memo} <- fetch(sha256, memo) do
      if current?(verdict), do: {:ok, verdict, memo}, else: record(sha256, payload, memo)
    end
  end

  def ensure(_file, _payload, _memo), do: {:error, :image_verdict_payload_mismatch}

  @doc "Whether the verdict was produced by the current rules."
  @spec current?(ImageVerdict.t() | nil) :: boolean()
  def current?(%ImageVerdict{check_version: version}),
    do: version == ImageProcessor.check_version()

  def current?(nil), do: false

  @doc "Classifies a verdict for request use; a missing or stale one is `:unchecked`."
  @spec classify(ImageVerdict.t() | nil) :: classification()
  def classify(%ImageVerdict{} = verdict),
    do: if(current?(verdict), do: verdict.status, else: :unchecked)

  def classify(nil), do: :unchecked

  defp record(sha256, payload, memo) do
    result =
      case ImageProcessor.validate(payload) do
        {:ok, info} ->
          %{status: :valid, mime_type: info.mime_type, width: info.width, height: info.height}

        {:error, reason} ->
          %{status: :invalid, reason: reason |> format_reason() |> truncate(@max_reason_length)}
      end

    attrs =
      Map.merge(
        %{mime_type: nil, width: nil, height: nil, reason: nil},
        Map.merge(result, %{sha256: sha256, check_version: ImageProcessor.check_version()})
      )

    ImageVerdict
    |> Ash.Changeset.for_create(:record, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, verdict} -> {:ok, verdict, Map.put(memo, sha256, verdict)}
      {:error, reason} -> {:error, {:record_image_verdict_failed, reason}}
    end
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp format_reason({format, reason}) when is_atom(format) and is_atom(reason),
    do: "#{format}:#{reason}"

  defp format_reason(_reason), do: "invalid"

  defp truncate(value, length), do: String.slice(value, 0, length)

  # Lowercase hex, as stored on `IntellectualClub.Files.File`.
  @doc false
  def sha256?(value) when is_binary(value) and byte_size(value) == 64,
    do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)

  def sha256?(_value), do: false
end
