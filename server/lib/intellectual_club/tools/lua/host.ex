defmodule IntellectualClub.Tools.Lua.Host do
  @moduledoc "State-preserving boundaries for SDK callbacks and nested Lua calls."
  alias Lua.VM.Executor

  def set(lua, path, callback), do: Lua.set!(lua, path, protect(callback))
  def encode(lua, callback), do: Lua.encode!(lua, protect(callback))

  # The public raising API wraps exceptions and loses their raise-time state.
  # Nested calls must keep both that state and the original Lua error value.
  def call(lua, function, args) do
    {values, state} = Executor.call_function(function, args, lua.state)
    {values, %{lua | state: state}}
  end

  def error!(message, lua), do: raise(Lua.VM.RuntimeError, value: message, state: lua.state)

  defp protect(callback) do
    fn args, lua ->
      try do
        callback.(args, lua)
      rescue
        exception in ArgumentError -> {:error, Exception.message(exception), lua}
      end
    end
  end
end
