defmodule IntellectualClub.Test.GenerationRuntime.CompactionAdapter do
  @moduledoc """
  OpenRouter request building with a scripted stream and a steering preparation
  barrier for checkpoint publication races. Tests release each injection after
  inspecting its request context or changing a queued command snapshot.
  """

  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion
  alias IntellectualClub.Test.GenerationRuntime.ScriptedAdapter

  defdelegate build_initial_request(opts), to: OpenRouterChatCompletion
  defdelegate request_snapshot(request), to: OpenRouterChatCompletion
  defdelegate stream_generate(opts, emit), to: ScriptedAdapter

  def build_followup_request(%{context: context} = opts) do
    if Map.get(context, :test_compaction_followup_barrier?, false) do
      send(context.test_pid, {:compaction_followup, self(), opts})

      receive do
        :build_followup -> :ok
      after
        5_000 -> raise "Compaction follow-up barrier timed out"
      end
    end

    OpenRouterChatCompletion.build_followup_request(opts)
  end

  def inject_steering(request, items, context) do
    send(context.test_pid, {:compaction_injection, self(), request, items, context})

    receive do
      :inject_steering ->
        OpenRouterChatCompletion.inject_steering(request, items, context)

      {:inject_steering, before_injection} ->
        before_injection.()
        OpenRouterChatCompletion.inject_steering(request, items, context)
    after
      5_000 -> raise "Compaction steering barrier timed out"
    end
  end
end
