defmodule IntellectualClub.GenerationContext.CallTrace do
  @moduledoc """
  Counts calls of selected functions made by the test process while a function
  runs, using Erlang call tracing (local calls included).

  Intended for `:whitebox` tests that pin how much work an implementation does:

      {result, calls} = count_calls([{Codec, :hash_iodata, 1}], fn -> ... end)
      assert calls[{Codec, :hash_iodata, 1}] == 2

  Functions that were not called are absent from the returned map. Only one
  trace may be active per process at a time.
  """

  import ExUnit.Assertions

  @doc "Runs `fun` and returns `{result, %{mfa => call_count}}` for the traced `mfas`."
  def count_calls(mfas, fun) when is_list(mfas) and is_function(fun, 0) do
    child_id = make_ref()
    tracer = ExUnit.Callbacks.start_supervised!({Task, fn -> collect(%{}) end}, id: child_id)
    Enum.each(mfas, fn {module, _function, _arity} -> Code.ensure_loaded!(module) end)
    Enum.each(mfas, &:erlang.trace_pattern(&1, true, [:local]))
    :erlang.trace(self(), true, [:call, :arity, {:tracer, tracer}])

    try do
      result = fun.()
      :erlang.trace(self(), false, [:call])
      ref = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^ref}
      send(tracer, {:counts, self()})
      assert_receive {:counts, calls}
      {result, calls}
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(mfas, &:erlang.trace_pattern(&1, false, [:local]))
      ExUnit.Callbacks.stop_supervised!(child_id)
    end
  end

  defp collect(calls) do
    receive do
      {:trace, _pid, :call, mfa} ->
        collect(Map.update(calls, mfa, 1, &(&1 + 1)))

      {:counts, caller} ->
        send(caller, {:counts, calls})
        collect(calls)
    end
  end
end
