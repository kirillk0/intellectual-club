defmodule IntellectualClub.Tools.Drivers.NativeAgentManagementTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Tools.Drivers.NativeAgentManagement
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  test "exposes fixed management functions" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    functions = NativeAgentManagement.fixed_functions(tool_instance)

    assert Enum.map(functions, & &1["name"]) == ["handoff", "sleep"]

    assert %{"schema" => handoff_schema} =
             Enum.find(functions, &(&1["name"] == "handoff"))

    assert handoff_schema["required"] == ["summary"]

    assert %{"schema" => sleep_schema} =
             Enum.find(functions, &(&1["name"] == "sleep"))

    assert sleep_schema["required"] == ["seconds"]
    assert sleep_schema["properties"]["seconds"]["type"] == "number"
  end

  test "handoff creates child chat and starts generation" do
    %{user: actor} = user_fixture()
    source = create_chat!(actor, "Tool source")
    {:ok, user_message} = Threads.add_message_to_end(source, :user, "Start", actor: actor)

    {:ok, assistant} =
      Threads.add_message(source, :assistant, "Working", actor: actor, parent_id: user_message.id)

    context = %ExecutionContext{
      owner_id: actor.id,
      chat_id: source.id,
      message_id: assistant.id,
      assistant_message_id: assistant.id
    }

    assert {:ok, %ExecutionResult{} = result} =
             NativeAgentManagement.execute(
               create_tool_instance!(actor),
               "handoff",
               %{"summary" => "Continue in the new chat."},
               context
             )

    payload = result.raw["handoff"]
    assert is_integer(payload["chat_id"])
    assert is_integer(payload["message_id"])
    assert is_integer(payload["generation_message_id"])

    target =
      Chat
      |> Ash.get!(payload["chat_id"], actor: actor, load: [:last_message])

    assert target.parent_chat_id == source.id
    assert target.parent_message_id == assistant.id
    assert target.parent_relation_kind == :handoff

    assert wait_until(fn ->
             generation_message =
               Ash.get!(ChatMessage, payload["generation_message_id"], actor: actor)

             generation_message.status == :done
           end)
  end

  test "handoff requires summary and execution context" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    assert {:error, message} =
             NativeAgentManagement.execute(tool_instance, "handoff", %{}, %ExecutionContext{})

    assert String.contains?(message, "summary")

    assert {:error, "Handoff requires generation execution context."} =
             NativeAgentManagement.execute(tool_instance, "handoff", %{"summary" => "ok"}, nil)
  end

  test "sleep pauses without execution context" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %ExecutionResult{} = result} =
             NativeAgentManagement.execute(tool_instance, "sleep", %{"seconds" => 0.02}, nil)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms >= 15
    assert result.text == "Paused for 0.02 seconds."
    assert result.raw["sleep"]["seconds"] == 0.02
    assert result.raw["sleep"]["milliseconds"] == 20
  end

  test "sleep validates duration" do
    %{user: actor} = user_fixture()
    tool_instance = create_tool_instance!(actor)

    assert {:error, message} =
             NativeAgentManagement.execute(tool_instance, "sleep", %{"seconds" => -1}, nil)

    assert String.contains?(message, "seconds")

    assert {:error, message} =
             NativeAgentManagement.execute(tool_instance, "sleep", %{}, nil)

    assert String.contains?(message, "seconds")
  end

  defp create_chat!(actor, title) do
    Chat
    |> Ash.Changeset.for_create(:create_empty, %{title: title, note: "", variables: %{}},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_tool_instance!(actor) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-agent-management",
        name: "Agent management",
        description: "",
        alias: "agent_management",
        config: %{},
        secrets: %{},
        max_output_tokens: 20_000
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp wait_until(fun, timeout_ms \\ 1_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_wait_until(fun, deadline)
      else
        false
      end
    end
  end
end
