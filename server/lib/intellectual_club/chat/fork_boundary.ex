defmodule IntellectualClub.Chat.ForkBoundary do
  @moduledoc """
  Provider-independent synthetic results and steering at a linked fork boundary.

  These payloads describe completed parent calls; they must never execute tools.
  """

  alias IntellectualClub.Generation.ToolCall

  @spec results([ToolCall.t()], ToolCall.t(), String.t()) :: [map()]
  def results(calls, %ToolCall{} = selected_call, task) when is_list(calls) do
    Enum.map(calls, fn %ToolCall{} = call ->
      if call.item_id == selected_call.item_id do
        selected_result(call, task)
      else
        skipped_result(call, selected_call)
      end
    end)
  end

  @spec steering(String.t()) :: String.t()
  def steering(task) do
    "FORK CONTROL MESSAGE\n\n" <>
      "The preceding assistant response and fork tool call were produced by the parent " <>
      "branch and are already complete. They are context only. You are now operating in " <>
      "a separate forked subagent branch.\n\n" <>
      "Execute only the task below. Do not continue the parent conversation, its ROOT ROLE, " <>
      "its pending plan, or any sibling tool calls. Do not repeat tool calls merely because " <>
      "the parent was instructed to make them. Use a tool only when the task below itself " <>
      "requires that tool. Begin the task immediately without explaining this branch " <>
      "transition. When the task is complete, return its answer directly; that answer becomes " <>
      "the fork result sent to the parent.\n\nTask:\n#{task}"
  end

  defp selected_result(%ToolCall{} = call, task) do
    %{
      text:
        "Fork branch initialized. The parent response is complete; follow only the next " <>
          "user instruction.",
      result_raw: %{
        "fork_instruction" => %{
          "subagent" => true,
          "task" => task
        }
      },
      media_contents: [],
      artifact_contents: [],
      call_id: call.call_id,
      name: call.name,
      args: call.args || %{}
    }
  end

  defp skipped_result(%ToolCall{} = call, %ToolCall{} = selected_call) do
    %{
      text:
        "Skipped in this forked branch because this call is unrelated to the selected " <>
          "subagent task. Do not retry it.",
      result_raw: %{
        "fork_skipped" => %{
          "skipped" => true,
          "reason" => "not_selected_for_subagent",
          "selected_tool_call_id" => selected_call.call_id
        }
      },
      media_contents: [],
      artifact_contents: [],
      call_id: call.call_id,
      name: call.name,
      args: call.args || %{}
    }
  end
end
