defmodule IntellectualClub.Files.ImageProviderVerdicts do
  @moduledoc """
  Facts about what one LLM configuration did with an image payload, keyed by the
  payload SHA-256 (lowercase hex, as stored on `IntellectualClub.Files.File`) and
  the configuration id.

  A configuration has `:accepted` an image when a response to a request with it
  completed, and `:rejected` it when the provider refused a request image and
  the image was blamed. Request preparation and hydration replace only images
  rejected by the current configuration with text; other configurations still
  receive them. A rejection overwrites an earlier fact; an acceptance never
  does.

  `forget/2` removes facts from the console, for example after a wrong blame:

      IntellectualClub.Files.ImageProviderVerdicts.forget([sha256], llm_configuration_id: 82)
  """

  require Ash.Query

  alias IntellectualClub.Files.{ImageProviderVerdict, ImageVerdicts}

  @max_details_length 1_000

  @type status :: :accepted | :rejected
  @type facts :: %{optional(String.t()) => status()}

  @doc """
  Loads the facts of `llm_configuration_id` for `sha256s` with one query:
  `sha256 => status` for hashes with a fact. Without a configuration or hashes
  no query is made; malformed hashes are ignored.
  """
  @spec load([String.t()], integer() | nil) :: {:ok, facts()} | {:error, term()}
  def load(sha256s, llm_configuration_id) when is_list(sha256s) do
    sha256s = sha256s |> Enum.filter(&ImageVerdicts.sha256?/1) |> Enum.uniq()

    if sha256s == [] or not is_integer(llm_configuration_id) do
      {:ok, %{}}
    else
      ImageProviderVerdict
      |> Ash.Query.filter(llm_configuration_id == ^llm_configuration_id and sha256 in ^sha256s)
      |> Ash.Query.select([:sha256, :status])
      |> Ash.read(authorize?: false)
      |> case do
        {:ok, verdicts} -> {:ok, Map.new(verdicts, &{&1.sha256, &1.status})}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Records that `llm_configuration_id` rejected these payloads, overwriting
  earlier facts. `details` is a short diagnostic (for example the provider and
  its error message), truncated to #{@max_details_length} characters. All rows are
  written in one statement.
  """
  @spec mark_rejected([String.t()], integer(), String.t() | nil) :: :ok | {:error, term()}
  def mark_rejected(sha256s, llm_configuration_id, details \\ nil)

  def mark_rejected(sha256s, llm_configuration_id, details)
      when is_list(sha256s) and is_integer(llm_configuration_id) and
             (is_binary(details) or is_nil(details)) do
    details = details && String.slice(details, 0, @max_details_length)

    write(sha256s, llm_configuration_id, :mark_rejected, %{details: details})
  end

  def mark_rejected(_sha256s, _llm_configuration_id, _details), do: {:error, :invalid_arguments}

  @doc """
  Records that `llm_configuration_id` accepted these payloads, in one statement.
  Existing facts are kept, in particular rejections.
  """
  @spec record_accepted([String.t()], integer()) :: :ok | {:error, term()}
  def record_accepted(sha256s, llm_configuration_id)
      when is_list(sha256s) and is_integer(llm_configuration_id),
      do: write(sha256s, llm_configuration_id, :record_accepted, %{})

  def record_accepted(_sha256s, _llm_configuration_id), do: {:error, :invalid_arguments}

  @doc """
  Removes facts, for example from the console after a wrong blame, so that the
  images are sent again. `sha256s` is a list of hashes or `:all`; the
  `:llm_configuration_id` option limits removal to one configuration. Returns
  the number of removed facts.
  """
  @spec forget([String.t()] | :all, keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def forget(sha256s, opts \\ [])

  def forget(sha256s, opts) when (is_list(sha256s) or sha256s == :all) and is_list(opts) do
    configuration_id = Keyword.get(opts, :llm_configuration_id)

    cond do
      is_list(sha256s) and not Enum.all?(sha256s, &ImageVerdicts.sha256?/1) ->
        {:error, :invalid_sha256}

      not (is_nil(configuration_id) or is_integer(configuration_id)) ->
        {:error, :invalid_llm_configuration_id}

      sha256s == [] ->
        {:ok, 0}

      true ->
        ImageProviderVerdict
        |> filter_sha256s(sha256s)
        |> filter_configuration(configuration_id)
        |> Ash.bulk_destroy(:destroy, %{},
          authorize?: false,
          strategy: [:atomic, :stream],
          return_records?: true,
          return_errors?: true
        )
        |> case do
          %Ash.BulkResult{status: :success, records: records} -> {:ok, length(records || [])}
          %Ash.BulkResult{errors: errors} -> {:error, {:forget_provider_verdicts_failed, errors}}
        end
    end
  end

  def forget(_sha256s, _opts), do: {:error, :invalid_arguments}

  defp write(sha256s, llm_configuration_id, action, attrs) do
    cond do
      not Enum.all?(sha256s, &ImageVerdicts.sha256?/1) ->
        {:error, :invalid_sha256}

      sha256s == [] ->
        :ok

      true ->
        # A stable order keeps concurrent upserts from deadlocking on row locks.
        sha256s
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.map(&Map.merge(attrs, %{sha256: &1, llm_configuration_id: llm_configuration_id}))
        |> Ash.bulk_create(ImageProviderVerdict, action,
          authorize?: false,
          transaction: false,
          return_records?: false,
          return_errors?: true,
          stop_on_error?: true
        )
        |> case do
          %Ash.BulkResult{status: :success} -> :ok
          %Ash.BulkResult{errors: errors} -> {:error, {action, errors}}
        end
    end
  end

  defp filter_sha256s(query, :all), do: query
  defp filter_sha256s(query, sha256s), do: Ash.Query.filter(query, sha256 in ^Enum.uniq(sha256s))

  defp filter_configuration(query, nil), do: query

  defp filter_configuration(query, configuration_id),
    do: Ash.Query.filter(query, llm_configuration_id == ^configuration_id)
end
