defmodule IntellectualClub.Generation.StepRequests.Codec do
  @moduledoc """
  Domain-independent, lossless full/patch encoding for normalized JSON objects.

  Hashes and the 50% size decision use compact JSON with sorted object keys
  and canonical decimal numbers, stable across JSONB numeric reserialization.
  Checkpoint distance is the number of patches since the last full object.
  The hard read bound is 32; writers may choose a smaller bound.
  """

  alias IntellectualClub.Generation.StepRequests.Error

  @max_chain 32
  @fields [
    :raw_request,
    :request_mode,
    :request_patch,
    :request_hash,
    :request_base_hash,
    :request_base_sequence,
    :request_checkpoint_distance
  ]

  def fields, do: @fields
  def max_chain, do: @max_chain

  def normalize!(request) when is_map(request) and not is_struct(request) do
    normalize_value!(request)
  end

  def normalize!(_request), do: fail!(:expected_json_object)

  def hash(request), do: request |> normalize_value!() |> encode() |> hash_iodata()

  defp hash_iodata(json), do: :crypto.hash(:sha256, json) |> Base.encode16(case: :lower)

  def json!(value), do: value |> normalize_value!() |> encode() |> IO.iodata_to_binary()

  def create_attributes(request, opts \\ []) do
    request = normalize!(request)
    sequence = Keyword.get(opts, :sequence, 1)
    limit = chain_limit!(opts)
    previous = Keyword.get(opts, :previous_step)
    previous_request = Keyword.get(opts, :previous_request)
    json = encode(request)
    full = full(request, hash_iodata(json))

    unless is_integer(sequence) and sequence > 0, do: fail!(:invalid_sequence)

    if sequence == 1 or Keyword.get(opts, :force_full, false) or
         not usable_previous?(previous, previous_request, sequence, limit) do
      full
    else
      previous_request = normalize!(previous_request)
      base_hash = previous_request |> encode() |> hash_iodata()

      if is_nil(Map.get(previous, :request_hash)) or previous.request_hash == base_hash do
        patch_or_full(full, IO.iodata_length(json), previous, previous_request, base_hash)
      else
        full
      end
    end
  end

  def chain_limit!(opts) do
    limit = Keyword.get(opts, :max_chain, @max_chain)
    unless is_integer(limit) and limit in 1..@max_chain, do: fail!(:invalid_max_chain)
    limit
  end

  defp full(request, hash) do
    %{
      request_mode: :full,
      raw_request: request,
      request_patch: nil,
      request_hash: hash,
      request_base_hash: nil,
      request_base_sequence: nil,
      request_checkpoint_distance: 0
    }
  end

  defp usable_previous?(previous, request, sequence, limit)
       when is_map(previous) and is_map(request) and not is_struct(request) do
    distance = Map.get(previous, :request_checkpoint_distance, 0)
    mode = Map.get(previous, :request_mode, :full)

    Map.get(previous, :sequence) == sequence - 1 and
      is_integer(distance) and distance >= 0 and distance < limit and
      ((mode == :full and distance == 0) or (mode == :patch and distance > 0))
  end

  defp usable_previous?(_previous, _request, _sequence, _limit), do: false

  defp patch_or_full(full, full_size, previous, previous_request, base_hash) do
    request = full.raw_request
    patch = previous_request |> Jsonpatch.diff(request) |> normalize_value!()
    validate_patch!(patch)

    # The dependency's diff considers 1 and 1.0 equal. Verify the exact normalized
    # result as well as the hash, and fall back instead of changing logical data.
    if IO.iodata_length(encode(patch)) * 2 < full_size and
         apply_normalized_patch!(previous_request, patch) === request do
      %{
        request_mode: :patch,
        raw_request: %{},
        request_patch: patch,
        request_hash: full.request_hash,
        request_base_hash: base_hash,
        request_base_sequence: Map.fetch!(previous, :sequence),
        request_checkpoint_distance: Map.get(previous, :request_checkpoint_distance, 0) + 1
      }
    else
      full
    end
  rescue
    # A diff is an optimization, never permission to alter or lose a request.
    _error -> full
  end

  @doc "Validates physical shape, normalizing JSON without requiring a predecessor."
  def validate_shape!(step) do
    sequence = Map.get(step, :sequence)
    unless is_integer(sequence) and sequence > 0, do: fail!(:invalid_sequence, step)
    attrs = Map.take(step, @fields)
    raw = normalize!(Map.get(attrs, :raw_request))
    attrs = Map.put(attrs, :raw_request, raw)

    case Map.get(attrs, :request_mode) do
      :full ->
        unless is_nil(attrs.request_patch) and is_nil(attrs.request_base_hash) and
                 is_nil(attrs.request_base_sequence) and attrs.request_checkpoint_distance == 0,
               do: fail!(:invalid_full_encoding, step)

        verify_hash!(attrs.request_hash, raw, step, true)
        attrs

      :patch ->
        unless sequence > 1 and raw == %{} and
                 attrs.request_base_sequence == sequence - 1 and
                 is_integer(attrs.request_checkpoint_distance) and
                 attrs.request_checkpoint_distance in 1..@max_chain and
                 valid_hash?(attrs.request_base_hash) and valid_hash?(attrs.request_hash),
               do: fail!(:invalid_patch_encoding, step)

        patch = normalize_value!(attrs.request_patch)
        validate_patch!(patch)
        Map.put(attrs, :request_patch, patch)

      _other ->
        fail!(:invalid_request_mode, step)
    end
  end

  @doc "Decodes one row, checking both the base and the reconstructed result."
  def decode!(step, previous \\ nil, previous_request \\ nil) do
    step |> validate_shape!() |> decode_request!(step, previous, previous_request)
  end

  @doc "Validates shape and reconstruction, resolving the base only for a valid patch."
  def validate_encoding!(step, resolve_base) when is_function(resolve_base, 1) do
    attrs = validate_shape!(step)

    if attrs.request_mode == :patch do
      {previous, base} = resolve_base.(attrs)
      _request = decode_request!(attrs, step, previous, base)
    end

    attrs
  end

  defp decode_request!(attrs, step, previous, previous_request) do
    case attrs.request_mode do
      :full ->
        attrs.raw_request

      :patch ->
        unless is_map(previous) and
                 Map.get(previous, :chat_message_id) == Map.get(step, :chat_message_id) and
                 Map.get(previous, :sequence) == attrs.request_base_sequence and
                 Map.get(previous, :request_checkpoint_distance) ==
                   attrs.request_checkpoint_distance - 1,
               do: fail!(:invalid_patch_base, step)

        base = normalize!(previous_request)
        verify_hash!(attrs.request_base_hash, base, step, false)
        request = apply_normalized_patch!(base, attrs.request_patch)
        verify_hash!(attrs.request_hash, request, step, false)
        request
    end
  end

  defp verify_hash!(nil, _request, _step, true), do: :ok

  defp verify_hash!(expected, request, step, _optional?) do
    unless valid_hash?(expected) and expected == hash_iodata(encode(request)),
      do: fail!(:hash_mismatch, step)
  end

  defp valid_hash?(hash), do: is_binary(hash) and Regex.match?(~r/\A[0-9a-f]{64}\z/, hash)

  def apply_patch!(request, patch) do
    validate_patch!(patch)
    request |> apply_operations!(patch) |> normalize!()
  rescue
    _error -> fail!(:invalid_patch)
  end

  # Only internal callers with normalized JSON and validated operations may skip
  # the recursive result normalization. Patch operations preserve those values;
  # the result must still be an object, and callers verify exact identity/hash.
  defp apply_normalized_patch!(request, patch) do
    case apply_operations!(request, patch) do
      result when is_map(result) and not is_struct(result) -> result
      _other -> fail!(:expected_json_object)
    end
  end

  defp apply_operations!(request, patch) do
    Enum.reduce(patch, request, fn operation, target ->
      validate_existing_paths!(operation, target)

      operation =
        case operation do
          %{"op" => "copy", "from" => "", "path" => path} ->
            %{"op" => "add", "path" => path, "value" => target}

          operation ->
            operation
        end

      case Jsonpatch.apply_patch(operation, target, keys: {:custom, &cast_fragment/4}) do
        {:ok, result} -> result
        {:error, _error} -> fail!(:invalid_patch)
      end
    end)
  rescue
    _error -> fail!(:invalid_patch)
  end

  # jsonpatch accepts a numeric prefix and an out-of-bounds remove at length.
  # Tighten these behaviors to RFC6901/6902 without changing generated patches.
  defp validate_existing_paths!(%{"op" => op, "path" => path} = operation, target) do
    if op in ["remove", "replace", "test"], do: fetch_pointer!(target, fragments(path))

    if op in ["copy", "move"] do
      from = fragments(operation["from"])
      _value = fetch_pointer!(target, from)
      destination = fragments(path)

      if op == "move" and length(destination) > length(from) and
           Enum.take(destination, length(from)) == from,
         do: fail!(:invalid_patch)
    end
  end

  defp fragments(""), do: []

  defp fragments("/" <> path) do
    path
    |> String.split("/")
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
  end

  defp fetch_pointer!(value, []), do: value

  defp fetch_pointer!(value, [fragment | rest]) when is_map(value) do
    case Map.fetch(value, fragment) do
      {:ok, found} -> fetch_pointer!(found, rest)
      :error -> fail!(:invalid_patch_pointer)
    end
  end

  defp fetch_pointer!(value, [fragment | rest]) when is_list(value) do
    case cast_fragment(fragment, [], value, []) do
      {:ok, index} when is_integer(index) and index < length(value) ->
        fetch_pointer!(Enum.at(value, index), rest)

      _other ->
        fail!(:invalid_patch_pointer)
    end
  end

  defp fetch_pointer!(_value, _fragments), do: fail!(:invalid_patch_pointer)

  defp cast_fragment(fragment, _path, target, _opts) when is_map(target), do: {:ok, fragment}
  defp cast_fragment("-", _path, target, _opts) when is_list(target), do: {:ok, :-}

  defp cast_fragment(fragment, _path, target, _opts) when is_list(target) do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, fragment) do
      index = String.to_integer(fragment)
      if index <= length(target), do: {:ok, index}, else: :error
    else
      :error
    end
  end

  defp validate_patch!(patch) when is_list(patch) do
    Enum.each(patch, fn
      %{"op" => op, "path" => path} = operation
      when op in ["add", "remove", "replace", "move", "copy", "test"] ->
        unless pointer?(path), do: fail!(:invalid_patch_pointer)

        if op in ["add", "replace", "test"] and not Map.has_key?(operation, "value"),
          do: fail!(:invalid_patch)

        if op in ["move", "copy"] and not pointer?(Map.get(operation, "from")),
          do: fail!(:invalid_patch_pointer)

      _operation ->
        fail!(:invalid_patch)
    end)
  end

  defp validate_patch!(_patch), do: fail!(:expected_patch_array)

  defp pointer?(""), do: true
  defp pointer?("/" <> path), do: not Regex.match?(~r/~(?![01])/, path)
  defp pointer?(_path), do: false

  defp normalize_value!(value) when is_map(value) and not is_struct(value) do
    Enum.reduce(value, %{}, fn {key, value}, result ->
      key = normalize_key!(key)
      if Map.has_key?(result, key), do: fail!(:duplicate_json_key)
      Map.put(result, key, normalize_value!(value))
    end)
  end

  defp normalize_value!(value) when is_list(value), do: Enum.map(value, &normalize_value!/1)
  defp normalize_value!(value) when value in [nil, true, false], do: value
  defp normalize_value!(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value!(value) when is_integer(value) or is_float(value), do: value

  defp normalize_value!(value) when is_binary(value) do
    # The standard fast-ASCII algorithm still checks every non-ASCII sequence.
    if String.valid?(value, :fast_ascii), do: value, else: fail!(:invalid_json_string)
  end

  defp normalize_value!(_value), do: fail!(:invalid_json_value)

  defp normalize_key!(key) when is_binary(key), do: normalize_value!(key)
  defp normalize_key!(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key!(_key), do: fail!(:invalid_json_key)

  defp encode(value) when is_map(value) do
    pairs =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [Jason.encode_to_iodata!(k), ":", encode(v)] end)

    ["{", Enum.intersperse(pairs, ","), "}"]
  end

  defp encode(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &encode/1), ","), "]"]

  defp encode(value) when is_integer(value) or is_float(value) do
    # JSONB can expand exponents and erase the sign of zero. Hash the JSON
    # number's decimal value, not its input spelling or BEAM integer/float type.
    # Integers are already materialized JSON values, not unbounded decimal input
    # strings. Avoid Decimal's string-parser precision cap; finite floats still
    # use Jason's shortest decimal spelling. JSON parser limits stay unchanged.
    decimal =
      if(is_integer(value),
        do: Decimal.new(value),
        else: value |> Jason.encode!() |> Decimal.new()
      )
      |> Decimal.normalize()

    if decimal.coef == 0,
      do: "0",
      else: Decimal.to_string(decimal, :scientific)
  end

  defp encode(value), do: Jason.encode_to_iodata!(value)

  defp fail!(reason, step \\ %{}), do: raise(Error, reason: reason, step_id: Map.get(step, :id))
end
