defmodule IntellectualClub.Tools.Lua.Runtime do
  @moduledoc """
  A fresh, capability-limited Lua VM per invocation. The host context is never
  constructed from Lua data, and this worker never accesses the database.
  """
  alias IntellectualClub.Tools.Lua.{Codec, Host, Http, Limits, Sandbox, Schema, Stdlib}
  alias Lua.VM.{State, Table, Value}

  @globals ~w(_G _ENV _VERSION assert error ipairs next pairs pcall xpcall rawequal rawget rawset rawlen select setmetatable getmetatable tonumber tostring type unpack math string table utf8 os)
  @libraries %{
    "math" =>
      ~w(abs acos asin atan ceil cos deg exp floor fmod log max min modf pi rad random randomseed sin sqrt tan tointeger type ult huge maxinteger mininteger),
    "string" =>
      ~w(byte char find format gmatch gsub len lower match pack packsize rep reverse sub unpack upper),
    "table" => ~w(concat insert move pack remove sort unpack),
    "utf8" => ~w(char charpattern codes codepoint len offset),
    "os" => ~w(clock date difftime time time_ms time_us)
  }

  @seq """
  seq = {}
  function seq.map(xs, f)
    local result = json.array()
    for i, v in ipairs(xs) do result[i] = f(v, i) end
    return result
  end
  function seq.filter(xs, f)
    local result = json.array()
    for i, v in ipairs(xs) do if f(v, i) then table.insert(result, v) end end
    return result
  end
  function seq.reduce(xs, f, initial)
    local result = initial
    for i, v in ipairs(xs) do result = f(result, v, i) end
    return result
  end
  function seq.find(xs, f)
    for i, v in ipairs(xs) do if f(v, i) then return v, i end end
    return nil
  end
  function seq.any(xs, f)
    for i, v in ipairs(xs) do if f(v, i) then return true end end
    return false
  end
  function seq.all(xs, f)
    for i, v in ipairs(xs) do if not f(v, i) then return false end end
    return true
  end
  """

  def validate_arguments(args, schema, owner_id) do
    Sandbox.run(owner_id, fn ->
      safely(fn ->
        Codec.validate!(args)
        Schema.validate(args, schema)
      end)
    end)
  end

  def validate_source(source, owner_id) do
    Sandbox.run(owner_id, fn ->
      safely(fn ->
        case Lua.parse_chunk(source) do
          {:ok, _chunk} -> :ok
          {:error, error} -> {:error, safe_message(error)}
        end
      end)
    end)
  end

  def execute(source, name, args, state, permissions, secrets, owner_id) do
    Sandbox.run(owner_id, fn ->
      safely(fn ->
        Codec.validate!(args)
        Codec.validate!(state)
        Process.put({__MODULE__, :http_count}, 0)
        Process.put({__MODULE__, :logs}, {[], 0})
        lua = environment(permissions, secrets)
        {args_ref, lua} = Codec.encode(args, lua)
        {ctx_ref, lua} = Codec.encode(%{"state" => state}, lua)
        {exports, lua} = chunk!(source, lua)
        exports = single!(exports, "Source must return exactly one table of exported functions")
        handler = Codec.field(lua, exports, name)
        {results, lua} = Lua.call_function!(lua, handler, [args_ref, ctx_ref])

        result =
          case results do
            [] -> nil
            [result] -> Codec.decode!(result, lua)
            _ -> raise ArgumentError, "An exported function must return one JSON value"
          end

        state = Codec.field(lua, ctx_ref, "state") |> Codec.decode!(lua)
        if not is_map(state), do: raise(ArgumentError, "ctx.state must be a JSON object")
        {logs, _bytes} = Process.get({__MODULE__, :logs})
        {:ok, %{"result" => result, "logs" => Enum.reverse(logs)}, state}
      end)
    end)
  end

  defp environment(permissions, secrets) do
    lua =
      Lua.new(
        sandboxed: [],
        max_instructions: Limits.get(:max_instructions),
        max_call_depth: Limits.get(:max_call_depth),
        max_string_bytes: Limits.get(:max_string_bytes)
      )

    state =
      State.update_table(lua.state, State.g_ref(lua.state), fn table ->
        Table.replace_data(table, Map.take(Table.to_map(table), @globals))
      end)

    state =
      Enum.reduce(@libraries, state, fn {name, allowed}, state ->
        State.update_table(state, State.get_global(state, name), fn table ->
          Table.replace_data(table, Map.take(Table.to_map(table), allowed))
        end)
      end)

    lua = %{lua | state: state} |> Codec.install() |> Stdlib.install()

    lua =
      Host.set(lua, ["print"], fn args, lua ->
        {logs, bytes} = Process.get({__MODULE__, :logs})
        message = Enum.map_join(args, "\t", &Value.to_string/1)
        message = if String.valid?(message), do: message, else: "[non-UTF-8 output]"

        if bytes + byte_size(message) + 1 > Limits.get(:log_bytes),
          do: raise(ArgumentError, "Lua print log limit exceeded")

        Process.put({__MODULE__, :logs}, {[message | logs], bytes + byte_size(message) + 1})
        {[], lua}
      end)

    lua =
      Host.set(lua, ["http", "request"], fn
        [params], lua ->
          count = Process.get({__MODULE__, :http_count})

          if count >= Limits.get(:http_calls),
            do: raise(ArgumentError, "HTTP request limit exceeded")

          Process.put({__MODULE__, :http_count}, count + 1)
          params = Codec.decode!(params, lua)

          case Http.request(params, permissions, secrets) do
            {:ok, response} ->
              {value, lua} = Codec.encode(response, lua)
              {[value], lua}

            {:error, message} ->
              {:error, message, lua}
          end

        _, lua ->
          {:error, "http.request expects one request object", lua}
      end)

    {_result, lua} = chunk!(@seq, lua)
    lua
  end

  # Avoid the dependency's eager display/decode traversal of returned tables.
  # The version is pinned: Codec, Host and Stdlib also use raw VM APIs.
  defp chunk!(source, lua) do
    case Lua.parse_chunk(source) do
      {:ok, chunk} ->
        {:ok, result, state} = Lua.VM.execute(chunk.prototype, lua.state)
        {result, %{lua | state: state}}

      {:error, error} ->
        raise error
    end
  end

  defp single!([value], _message), do: value
  defp single!(_, message), do: raise(ArgumentError, message)

  defp safely(fun) do
    fun.()
  rescue
    exception in [
      Lua.RuntimeException,
      Lua.CompilerException,
      Lua.VM.RuntimeError,
      Lua.VM.TypeError,
      Lua.VM.ArgumentError,
      Lua.VM.AssertionError,
      ArgumentError
    ] ->
      {:error, safe_message(exception)}

    _exception ->
      {:error, "Lua execution failed; check the script and its JSON values."}
  catch
    _kind, _reason -> {:error, "Lua execution stopped."}
  end

  defp safe_message(exception) do
    message = Exception.message(exception)
    message = Regex.replace(~r/\e\[[0-9;]*m/, message, "")

    if String.valid?(message),
      do: String.slice(message, 0, 4_096),
      else: "Lua execution failed (non-UTF-8 error)."
  end
end
