defmodule IntellectualClub.Tools.Lua.Schema do
  @moduledoc """
  A strict, local JSON Schema subset for Lua tool arguments.

  Schemas are objects limited to 64 KiB of encoded JSON and 32 nested JSON
  containers. Unknown keywords, references, regexes, and boolean schemas are
  rejected. `min` and `max` are supported aliases of `minimum` and `maximum`.
  Annotations do not modify input values or insert defaults. Input size and
  nesting limits are enforced by the runtime before calling this module.
  """

  @max_schema_bytes 64 * 1024
  @max_depth 32
  @types ~w(object array string number integer boolean null)
  @keywords ~w(type properties required additionalProperties items minItems maxItems
               minLength maxLength min max minimum maximum exclusiveMinimum
               exclusiveMaximum multipleOf enum const description title default anyOf oneOf allOf)
  @counts ~w(minItems maxItems minLength maxLength)
  @bounds ~w(min max minimum maximum exclusiveMinimum exclusiveMaximum)
  @combinations ~w(anyOf oneOf allOf)

  @spec validate_schema(term()) :: :ok | {:error, String.t()}
  def validate_schema(schema) when is_map(schema) and not is_struct(schema) do
    with {:ok, _remaining} <- json(schema, "schema", 0, @max_schema_bytes) do
      schema_node(schema, "schema")
    end
  end

  def validate_schema(_schema), do: error("schema", "must be an object with string keys")

  @spec validate(term(), term()) :: :ok | {:error, String.t()}
  def validate(value, schema) do
    with :ok <- validate_schema(schema),
         {:ok, :unlimited} <- json(value, "$", 0, :unlimited) do
      validate_node(value, schema, "$")
    end
  end

  defp schema_node(schema, path) when is_map(schema) do
    each(schema, fn {keyword, value} -> schema_keyword(keyword, value, child(path, keyword)) end)
  end

  defp schema_node(_schema, path), do: error(path, "must be a schema object")

  defp schema_keyword("type", value, path) do
    cond do
      value in @types ->
        :ok

      is_list(value) and value != [] and Enum.all?(value, &(&1 in @types)) ->
        unique(value, path)

      true ->
        error(path, "must be a supported type or a nonempty array of unique supported types")
    end
  end

  defp schema_keyword("properties", value, path) when is_map(value) do
    each(value, fn {name, schema} -> schema_node(schema, child(path, name)) end)
  end

  defp schema_keyword("properties", _value, path), do: error(path, "must be an object of schemas")

  defp schema_keyword("required", value, path) when is_list(value) do
    if Enum.all?(value, &is_binary/1),
      do: unique(value, path),
      else: error(path, "must be an array of unique property names")
  end

  defp schema_keyword("required", _value, path),
    do: error(path, "must be an array of unique property names")

  defp schema_keyword("additionalProperties", value, _path) when is_boolean(value), do: :ok
  defp schema_keyword("additionalProperties", value, path), do: schema_node(value, path)
  defp schema_keyword("items", value, path), do: schema_node(value, path)

  defp schema_keyword(keyword, value, path) when keyword in @counts do
    if integer_number?(value) and value >= 0,
      do: :ok,
      else: error(path, "must be a nonnegative integer")
  end

  defp schema_keyword(keyword, value, path) when keyword in @bounds do
    if is_number(value), do: :ok, else: error(path, "must be a finite number")
  end

  defp schema_keyword("multipleOf", value, path) do
    if is_number(value) and value > 0,
      do: :ok,
      else: error(path, "must be a positive finite number")
  end

  defp schema_keyword("enum", values, path) when is_list(values) and values != [] do
    unique(values, path)
  end

  defp schema_keyword("enum", _value, path),
    do: error(path, "must be a nonempty array of unique JSON values")

  defp schema_keyword(keyword, value, path) when keyword in ~w(description title) do
    if is_binary(value), do: :ok, else: error(path, "must be a string")
  end

  defp schema_keyword(keyword, _value, _path) when keyword in ~w(const default), do: :ok

  defp schema_keyword(keyword, schemas, path)
       when keyword in @combinations and is_list(schemas) and schemas != [] do
    each(Enum.with_index(schemas), fn {schema, index} ->
      schema_node(schema, "#{path}[#{index}]")
    end)
  end

  defp schema_keyword(keyword, _value, path) when keyword in @combinations,
    do: error(path, "must be a nonempty array of schema objects")

  defp schema_keyword(keyword, _value, path) when keyword not in @keywords,
    do:
      error(path, "unsupported schema keyword; remove it or use the supported JSON Schema subset")

  defp unique(values, path) do
    if length(Enum.uniq_by(values, &equality_key/1)) == length(values),
      do: :ok,
      else: error(path, "must not contain duplicate values")
  end

  # JSON numeric equality treats 1 and 1.0 as the same value, including in objects.
  defp equality_key(value) when is_float(value) do
    if integer_number?(value), do: trunc(value), else: value
  end

  defp equality_key(value) when is_list(value), do: Enum.map(value, &equality_key/1)

  defp equality_key(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, equality_key(item)} end)

  defp equality_key(value), do: value

  defp validate_node(value, schema, path) do
    each(schema, fn {keyword, constraint} -> check(value, keyword, constraint, schema, path) end)
  end

  defp check(value, "type", types, _schema, path) do
    if Enum.any?(List.wrap(types), &matches_type?(value, &1)),
      do: :ok,
      else: error(path, "must have type #{Enum.join(List.wrap(types), " or ")}")
  end

  defp check(value, "enum", choices, _schema, path) do
    if Enum.any?(choices, &(&1 == value)),
      do: :ok,
      else: error(path, "must equal one of the enum values")
  end

  defp check(value, "const", expected, _schema, path) do
    if value == expected, do: :ok, else: error(path, "must equal the const value")
  end

  defp check(value, "properties", properties, _schema, path) when is_map(value) do
    each(properties, fn {name, schema} ->
      case Map.fetch(value, name) do
        {:ok, item} -> validate_node(item, schema, child(path, name))
        :error -> :ok
      end
    end)
  end

  defp check(value, "required", names, _schema, path) when is_map(value) do
    each(names, fn name ->
      if Map.has_key?(value, name),
        do: :ok,
        else: error(child(path, name), "required property is missing")
    end)
  end

  defp check(value, "additionalProperties", constraint, schema, path) when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    each(value, fn {name, item} ->
      cond do
        Map.has_key?(properties, name) or constraint == true -> :ok
        constraint == false -> error(child(path, name), "additional property is not allowed")
        true -> validate_node(item, constraint, child(path, name))
      end
    end)
  end

  defp check(value, "items", schema, _parent, path) when is_list(value) do
    each(Enum.with_index(value), fn {item, index} ->
      validate_node(item, schema, "#{path}[#{index}]")
    end)
  end

  defp check(value, keyword, bound, _schema, path)
       when is_list(value) and keyword in ~w(minItems maxItems) do
    count_bound(length(value), keyword, bound, path)
  end

  defp check(value, keyword, bound, _schema, path)
       when is_binary(value) and keyword in ~w(minLength maxLength) do
    count_bound(length(String.to_charlist(value)), keyword, bound, path)
  end

  defp check(value, keyword, bound, _schema, path) when is_number(value) and keyword in @bounds do
    valid? =
      case keyword do
        key when key in ~w(min minimum) -> value >= bound
        key when key in ~w(max maximum) -> value <= bound
        "exclusiveMinimum" -> value > bound
        "exclusiveMaximum" -> value < bound
      end

    if valid?, do: :ok, else: error(path, "must satisfy #{keyword} #{bound}")
  end

  defp check(value, "multipleOf", divisor, _schema, path) when is_number(value) do
    {numerator, denominator} = decimal_ratio(value)
    {divisor_numerator, divisor_denominator} = decimal_ratio(divisor)

    if rem(numerator * divisor_denominator, divisor_numerator * denominator) == 0,
      do: :ok,
      else: error(path, "must be a multipleOf #{divisor}")
  end

  defp check(value, "allOf", schemas, _schema, path) do
    each(Enum.with_index(schemas), fn {schema, index} ->
      validate_node(value, schema, "#{path} (allOf[#{index}])")
    end)
  end

  defp check(value, "anyOf", schemas, _schema, path) do
    if Enum.any?(schemas, &(validate_node(value, &1, path) == :ok)),
      do: :ok,
      else: error(path, "must match at least one anyOf schema")
  end

  defp check(value, "oneOf", schemas, _schema, path) do
    count =
      Enum.reduce_while(schemas, 0, fn schema, count ->
        case validate_node(value, schema, path) do
          :ok when count == 1 -> {:halt, 2}
          :ok -> {:cont, 1}
          {:error, _message} -> {:cont, count}
        end
      end)

    if count == 1,
      do: :ok,
      else:
        error(
          path,
          "must match exactly one oneOf schema (matched #{if count == 2, do: "at least 2", else: "0"})"
        )
  end

  defp check(_value, _keyword, _constraint, _schema, _path), do: :ok

  defp count_bound(count, keyword, bound, path) do
    valid? = if keyword in ~w(minItems minLength), do: count >= bound, else: count <= bound
    if valid?, do: :ok, else: error(path, "must satisfy #{keyword} #{bound} (got #{count})")
  end

  defp matches_type?(value, "object"), do: is_map(value)
  defp matches_type?(value, "array"), do: is_list(value)
  defp matches_type?(value, "string"), do: is_binary(value)
  defp matches_type?(value, "number"), do: is_number(value)
  defp matches_type?(value, "integer"), do: integer_number?(value)
  defp matches_type?(value, "boolean"), do: is_boolean(value)
  defp matches_type?(value, "null"), do: is_nil(value)

  defp integer_number?(value),
    do: is_integer(value) or (is_float(value) and value == trunc(value))

  # Decimal arithmetic avoids both 0.3 / 0.1 rounding errors and float overflow.
  defp decimal_ratio(value) when is_integer(value), do: {value, 1}

  defp decimal_ratio(value) do
    [coefficient | exponent] = String.split(Float.to_string(value), "e")

    exponent =
      case exponent do
        [] -> 0
        [exponent] -> String.to_integer(exponent)
      end

    [whole, fraction] = String.split(coefficient, ".")
    numerator = String.to_integer(whole <> fraction)
    scale = byte_size(fraction) - exponent

    if scale >= 0,
      do: {numerator, Integer.pow(10, scale)},
      else: {numerator * Integer.pow(10, -scale), 1}
  end

  # Validate JSON before interpreting keywords. The shrinking byte budget stops
  # oversized documents before serializing them, including large strings/arrays.
  defp json(value, path, depth, remaining) when is_map(value) and not is_struct(value) do
    with :ok <- depth(depth, remaining, path),
         {:ok, remaining} <- spend(2, remaining, path) do
      Enum.reduce_while(value, {:ok, {remaining, 0}}, fn {key, item}, {:ok, {budget, index}} ->
        result =
          if is_binary(key) do
            with {:ok, budget} <- spend(if(index == 0, do: 1, else: 2), budget, path),
                 {:ok, budget} <- json(key, path, depth + 1, budget),
                 {:ok, budget} <- json(item, child(path, key), depth + 1, budget) do
              {:ok, {budget, index + 1}}
            end
          else
            error(path, "JSON object keys must be valid UTF-8 strings")
          end

        case result do
          {:ok, _state} -> {:cont, result}
          {:error, _message} -> {:halt, result}
        end
      end)
      |> case do
        {:ok, {budget, _index}} -> {:ok, budget}
        {:error, _message} = error -> error
      end
    end
  end

  defp json(value, path, depth, remaining) when is_list(value) do
    with :ok <- depth(depth, remaining, path),
         {:ok, remaining} <- spend(2, remaining, path) do
      json_array(value, path, depth + 1, remaining, 0)
    end
  end

  defp json(value, path, _depth, remaining) when is_binary(value) do
    with {:ok, _budget} <- spend(byte_size(value) + 2, remaining, path) do
      cond do
        not String.valid?(value) -> error(path, "must be a valid UTF-8 string")
        remaining == :unlimited -> {:ok, :unlimited}
        true -> spend(byte_size(Jason.encode!(value)), remaining, path)
      end
    end
  end

  defp json(value, path, _depth, remaining) when is_number(value) do
    cond do
      is_float(value) and not (value == value and abs(value) <= 1.7976931348623157e308) ->
        error(path, "JSON numbers must be finite")

      remaining == :unlimited ->
        {:ok, :unlimited}

      :erlang.external_size(value) > @max_schema_bytes ->
        size_error(path)

      true ->
        spend(byte_size(to_string(value)), remaining, path)
    end
  end

  defp json(value, path, _depth, remaining) when value in [true, false, nil],
    do: spend(if(value == false, do: 5, else: 4), remaining, path)

  defp json(_value, path, _depth, _remaining),
    do:
      error(
        path,
        "must be a JSON value (string-keyed object, array, string, finite number, boolean or null)"
      )

  defp json_array([], _path, _depth, remaining, _index), do: {:ok, remaining}

  defp json_array([item | rest], path, depth, remaining, index) do
    with {:ok, remaining} <- spend(if(index == 0, do: 0, else: 1), remaining, path),
         {:ok, remaining} <- json(item, "#{path}[#{index}]", depth, remaining) do
      json_array(rest, path, depth, remaining, index + 1)
    end
  end

  defp json_array(_value, path, _depth, _remaining, _index),
    do: error(path, "must be a proper JSON array")

  defp depth(_depth, :unlimited, _path), do: :ok
  defp depth(depth, _remaining, _path) when depth < @max_depth, do: :ok

  defp depth(_depth, _remaining, path),
    do: error(path, "schema nesting must not exceed 32 levels")

  defp spend(_bytes, :unlimited, _path), do: {:ok, :unlimited}
  defp spend(bytes, remaining, _path) when bytes <= remaining, do: {:ok, remaining - bytes}
  defp spend(_bytes, _remaining, path), do: size_error(path)

  defp size_error(path),
    do: error(path, "encoded schema JSON must not exceed 65536 bytes (64 KiB)")

  defp each(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp child(path, name), do: path <> "[" <> inspect(name, printable_limit: 80) <> "]"
  defp error(path, message), do: {:error, "#{path}: #{message}"}
end
