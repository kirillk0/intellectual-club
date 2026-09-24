defmodule IntellectualClub.Chat.ForkHistoryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.ChatShare
  alias IntellectualClub.Chat.ForkBoundary
  alias IntellectualClub.Chat.ForkHistory
  alias IntellectualClub.Chat.ForkHistoryCorruptFixture
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Context
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.ToolCall
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Llm.Providers.AnthropicMessages.Payload, as: AnthropicPayload
  alias IntellectualClub.Llm.Providers.Common.ChatHistory
  alias IntellectualClub.Llm.Providers.GoogleInteractions.Payload, as: GooglePayload
  alias IntellectualClub.Llm.Providers.Responses.HistoryInput

  @load [steps: [:raw_request, :raw_response, items: [contents: [:file]]]]
  @task "Inspect just this branch.\nPreserve task whitespace.  "
  @selected_text "Fork branch initialized. The parent response is complete; follow only the next user instruction."
  @skipped_text "Skipped in this forked branch because this call is unrelated to the selected subagent task. Do not retry it."

  setup do
    %{user: actor} = user_fixture()
    %{actor: actor}
  end

  test "boundary payloads preserve exact text, raw metadata and call identity" do
    selected = %ToolCall{item_id: 11, call_id: "selected", name: "agent__fork", args: nil}

    sibling = %ToolCall{
      item_id: 12,
      call_id: "sibling",
      name: "agent__fork",
      args: %{"task" => "other"}
    }

    assert [
             %{
               text: @selected_text,
               result_raw: %{"fork_instruction" => %{"subagent" => true, "task" => @task}},
               media_contents: [],
               artifact_contents: [],
               call_id: "selected",
               name: "agent__fork",
               args: %{}
             },
             %{
               text: @skipped_text,
               result_raw: %{
                 "fork_skipped" => %{
                   "skipped" => true,
                   "reason" => "not_selected_for_subagent",
                   "selected_tool_call_id" => "selected"
                 }
               },
               media_contents: [],
               artifact_contents: [],
               call_id: "sibling",
               name: "agent__fork",
               args: %{"task" => "other"}
             }
           ] == ForkBoundary.results([selected, sibling], selected, @task)

    expected =
      "FORK CONTROL MESSAGE\n\n" <>
        "The preceding assistant response and fork tool call were produced by the parent " <>
        "branch and are already complete. They are context only. You are now operating in " <>
        "a separate forked subagent branch.\n\n" <>
        "Execute only the task below. Do not continue the parent conversation, its ROOT ROLE, " <>
        "its pending plan, or any sibling tool calls. Do not repeat tool calls merely because " <>
        "the parent was instructed to make them. Use a tool only when the task below itself " <>
        "requires that tool. Begin the task immediately without explaining this branch " <>
        "transition. When the task is complete, return its answer directly; that answer becomes " <>
        "the fork result sent to the parent.\n\nTask:\n#{@task}"

    assert ForkBoundary.steering(@task) == expected
  end

  test "single-call prefix retains earlier history and substitutes only the boundary", %{
    actor: actor
  } do
    source = source!(actor, previous_step?: true)
    [call] = source.calls
    child = child!(source, actor)

    before =
      item!(source.step, 1, :steering, "Before response", actor, %{
        "placement" => "before_response"
      })

    item!(
      source.step,
      100,
      :tool_result,
      "PRIVATE REAL RESULT",
      actor,
      %{"raw" => %{"private" => true}},
      call.id
    )

    item!(source.step, 101, :artifact, "PRIVATE ARTIFACT", actor)

    item!(source.step, 102, :steering, "LATER PARENT TASK", actor, %{
      "placement" => "after_response"
    })

    item!(source.step, 103, :steering, "LEGACY LATER STEERING", actor)
    item!(source.step, 104, :error, "LATER PARENT ERROR", actor)
    persisted_before = Ash.get!(ChatMessage, source.message.id, actor: actor, load: @load)
    counts = trace_counts(actor)

    assert {:ok, [root, boundary]} = ForkHistory.prefix(child, actor)
    assert root.id == source.root.id
    assert boundary.id == source.message.id

    assert root.fork_inherited == %{
             source_chat_id: source.chat.id,
             source_message_id: source.root.id
           }

    assert boundary.fork_inherited == %{
             source_chat_id: source.chat.id,
             source_message_id: source.message.id
           }

    assert boundary.status == :done
    assert [previous, step] = boundary.steps
    persisted_previous = Enum.find(persisted_before.steps, &(&1.sequence == 1))
    assert previous.id == persisted_previous.id
    assert Enum.map(previous.items, & &1.id) == Enum.map(persisted_previous.items, & &1.id)
    assert step.status == :done
    assert step.response_final
    refute is_map(step.raw_response) and not is_struct(step.raw_response)
    refute is_map(step.raw_request) and not is_struct(step.raw_request)
    assert step.input_tokens == 7
    assert step.output_tokens == 3

    assert Enum.map(step.items, & &1.type) == [
             :steering,
             :reasoning,
             :answer,
             :tool_call,
             :tool_result,
             :steering
           ]

    assert hd(step.items).id == before.id
    result = Enum.find(step.items, &(&1.type == :tool_result))
    assert result.tool_call_item_id == call.id
    assert History.item_text(result) == @selected_text
    assert History.item_text(List.last(step.items)) == ForkBoundary.steering(@task)
    refute inspect(boundary) =~ "PRIVATE REAL RESULT"
    refute inspect(boundary) =~ "PRIVATE ARTIFACT"
    refute inspect(boundary) =~ "LATER PARENT"
    refute inspect(boundary) =~ "LEGACY LATER STEERING"
    persisted_after = Ash.get!(ChatMessage, source.message.id, actor: actor, load: @load)
    assert trace_snapshot(persisted_after) == trace_snapshot(persisted_before)
    assert trace_counts(actor) == counts
    assert Threads.all_messages(child.id, actor) == []
  end

  test "parallel results pair every call and project to every current provider format", %{
    actor: actor
  } do
    source = source!(actor, call_count: 3)
    child = child!(source, actor, selected_index: 1)
    assert {:ok, history} = ForkHistory.prefix(child.id, actor)
    step = history |> List.last() |> Map.fetch!(:steps) |> List.last()
    result_items = Enum.filter(step.items, &(&1.type == :tool_result))
    assert Enum.map(result_items, & &1.tool_call_item_id) == Enum.map(source.calls, & &1.id)

    assert Enum.map(result_items, &History.item_text/1) == [
             @skipped_text,
             @selected_text,
             @skipped_text
           ]

    [skipped, selected, _] = Enum.map(result_items, &(History.opaque_payloads(&1) |> hd()))
    assert selected["raw"] == %{"fork_instruction" => %{"subagent" => true, "task" => @task}}
    assert skipped["raw"]["fork_skipped"]["selected_tool_call_id"] == "call-2"

    assert selected["responses_item"] == %{
             "type" => "function_call_output",
             "call_id" => "call-2",
             "output" => @selected_text
           }

    responses = HistoryInput.build_input_items(history)

    assert Enum.map(Enum.filter(responses, &(&1["type"] == "function_call")), & &1["call_id"]) ==
             ["call-1", "call-2", "call-3"]

    outputs = Enum.filter(responses, &(&1["type"] == "function_call_output"))
    assert Enum.map(outputs, & &1["call_id"]) == ["call-1", "call-2", "call-3"]
    assert Enum.map(outputs, & &1["output"]) == [@skipped_text, @selected_text, @skipped_text]

    assert List.last(responses)["content"] == [
             %{"type" => "input_text", "text" => ForkBoundary.steering(@task)}
           ]

    messages = ChatHistory.build_messages(history)
    tools = Enum.filter(messages, &(&1["role"] == "tool"))
    assert Enum.map(tools, & &1["tool_call_id"]) == ["call-1", "call-2", "call-3"]
    assert Enum.map(tools, & &1["content"]) == [@skipped_text, @selected_text, @skipped_text]
    assert List.last(messages) == %{"role" => "user", "content" => ForkBoundary.steering(@task)}

    {_, anthropic} = AnthropicPayload.from_chat_messages(messages)
    blocks = Enum.flat_map(anthropic, & &1["content"])
    assert Enum.count(blocks, &(&1["type"] == "tool_use")) == 3
    assert Enum.count(blocks, &(&1["type"] == "tool_result")) == 3
    assert inspect(anthropic) =~ @selected_text
    assert inspect(anthropic) =~ @skipped_text

    google = GooglePayload.build_input_steps(history)
    assert Enum.count(google, &(&1["type"] == "function_call")) == 3
    assert Enum.count(google, &(&1["type"] == "function_result")) == 3
    assert inspect(google) =~ @selected_text
    assert inspect(google) =~ @skipped_text
  end

  test "source continuation and a different active leaf cannot extend the prefix", %{actor: actor} do
    source = source!(actor)
    child = child!(source, actor)
    assert {:ok, original} = ForkHistory.prefix(child, actor)
    later = step!(source.message, source.step.sequence + 1, actor)
    item!(later, 1, :answer, "LATER SOURCE STEP", actor)

    {:ok, _} =
      Threads.add_message(source.chat, :user, "LATER SOURCE MESSAGE",
        actor: actor,
        parent_id: source.message.id
      )

    {:ok, alternative} =
      Threads.add_message(source.chat, :assistant, "DIFFERENT ACTIVE BRANCH",
        actor: actor,
        parent_id: source.root.id
      )

    assert Ash.get!(Chat, source.chat.id, actor: actor).last_message_id == alternative.id
    assert {:ok, current} = ForkHistory.prefix(child, actor)
    assert current == original
  end

  test "source edits are live and chat note is not the fork task", %{actor: actor} do
    source = source!(actor)
    child = child!(source, actor)
    assert {:ok, original} = ForkHistory.prefix(child, actor)

    update_message_text!(source.root, "Edited root", actor)

    update_content!(source.answer, :text, %{content_text: "Edited boundary answer"}, actor)
    update_chat!(child, %{note: "This must not replace the task"}, actor)
    assert {:ok, [root, boundary]} = ForkHistory.prefix(child, actor)
    assert History.project_user_input_text(root) == "Edited root"
    assert History.project_text_for_item_type(boundary, :answer) == "Edited boundary answer"
    assert History.project_text_for_item_type(boundary, :steering) == ForkBoundary.steering(@task)
    refute [root, boundary] == original
  end

  test "source status cannot filter a completed fork boundary out of generation", %{actor: actor} do
    source = source!(actor)
    child = child!(source, actor)

    for {message_status, step_status} <- [
          generating: :waiting_tools,
          canceled: :canceled,
          error: :error,
          done: :done
        ] do
      update!(source.message, :set_generation_state, %{status: message_status}, actor)
      update!(source.step, :update, %{status: step_status}, actor)
      assert {:ok, [_, boundary]} = ForkHistory.prefix(child, actor)
      assert boundary.status == :done
      assert hd(boundary.steps).status == :done
      history = Context.history_for_generation!(child.id, actor: actor, parent_id: nil)
      assert Enum.map(history, & &1.role) == [:user, :assistant]
      assert List.last(history).content =~ "Parent completed response"
      refute inspect(history) =~ "turn_aborted"
    end
  end

  test "first generation and followups use inherited plus only the selected local branch", %{
    actor: actor
  } do
    configuration = configuration!(actor)
    source = source!(actor, chat_attrs: %{llm_configuration_id: configuration.id})
    child = child!(source, actor)
    first = Context.build!(child.id, actor: actor, parent_id: nil)

    assert first.history ==
             Context.history_for_generation!(child.id, actor: actor, parent_id: nil)

    assert Enum.map(first.history, & &1.role) == [:user, :assistant]
    assert inspect(first.request_payload) =~ @selected_text
    assert inspect(first.request_payload) =~ "FORK CONTROL MESSAGE"
    assert [local] = Threads.all_messages(child.id, actor)
    assert local.id == first.message_id
    assert local.parent_id == nil
    step = Ash.get!(ChatMessageStep, first.step_id, actor: actor)
    item!(step, 1, :answer, "Own completed answer", actor)
    update!(step, :update, %{status: :done, response_final: true}, actor)
    update!(local, :set_generation_state, %{status: :done}, actor)

    {:ok, prompt} =
      Threads.add_message(child, :user, "Follow up", actor: actor, parent_id: local.id)

    {:ok, other} =
      Threads.add_message(child, :user, "OTHER LOCAL BRANCH", actor: actor, parent_id: local.id)

    assert {:ok, branch} =
             ForkHistory.effective_branch(child, prompt.id, actor, load: @load, strict?: true)

    assert Enum.map(branch, & &1.id) == [source.root.id, source.message.id, local.id, prompt.id]
    refute Enum.any?(branch, &(&1.id == other.id))
    refute Map.has_key?(List.last(branch), :fork_inherited)
    followup = Context.build!(child.id, actor: actor, parent_id: prompt.id)

    assert followup.history ==
             Context.history_for_generation!(child.id, actor: actor, parent_id: prompt.id)

    assert Enum.map(followup.history, & &1.role) == [:user, :assistant, :assistant, :user]
    assert inspect(followup.request_payload) =~ @selected_text
    assert inspect(followup.request_payload) =~ "Own completed answer"
    refute inspect(followup.request_payload) =~ "OTHER LOCAL BRANCH"
  end

  test "nested linked forks recursively inherit live anchored prefixes", %{actor: actor} do
    source = source!(actor)
    child = child!(source, actor)
    inner = source!(actor, chat: child, root_text: "Inner root")
    grandchild = child!(inner, actor, task: "Inner task")
    assert {:ok, history} = ForkHistory.prefix(grandchild, actor)

    assert Enum.map(history, & &1.id) == [
             source.root.id,
             source.message.id,
             inner.root.id,
             inner.message.id
           ]

    assert Enum.map(history, & &1.fork_inherited.source_chat_id) == [
             source.chat.id,
             source.chat.id,
             child.id,
             child.id
           ]

    assert Enum.at(history, 1) |> History.project_text_for_item_type(:steering) ==
             ForkBoundary.steering(@task)

    assert List.last(history) |> History.project_text_for_item_type(:steering) ==
             ForkBoundary.steering("Inner task")

    update_message_text!(source.root, "Live ancestor edit", actor)

    assert {:ok, [root | _]} = ForkHistory.prefix(grandchild, actor)
    assert History.project_user_input_text(root) == "Live ancestor edit"
  end

  test "cycles fail closed without returning partial inherited data", %{actor: actor} do
    source = source!(actor)
    child = child!(source, actor)
    inner = source!(actor, chat: child)
    cycle = corrupt_anchor!(source.chat, link_attrs(inner, @task, 0), actor)
    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(cycle, actor)
    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(child, actor)

    assert {:error, :fork_context_unavailable} =
             ForkHistory.effective_branch(child, inner.message.id, actor)
  end

  test "the inherited prefix depth is bounded", %{actor: actor} do
    root = create_chat!(%{}, actor)

    {last, previous} =
      Enum.reduce(1..33, {root, nil}, fn _, {chat, _previous} ->
        source = source!(actor, chat: chat)
        {child!(source, actor), chat}
      end)

    assert {:ok, history} = ForkHistory.prefix(previous, actor)
    assert length(history) == 64
    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(last, actor)
  end

  test "missing or inconsistent anchors and selected calls fail closed", %{actor: actor} do
    source = source!(actor)
    child = child!(source, actor)

    for changes <- [
          %{parent_chat_id: nil},
          %{parent_message_id: source.root.id},
          %{parent_tool_call_item_id: nil},
          %{fork_source_step_id: nil},
          %{fork_task: nil}
        ] do
      current = corrupt_anchor!(child, changes, actor)
      assert {:error, :fork_context_unavailable} = ForkHistory.prefix(current, actor)
      corrupt_anchor!(current, link_attrs(source, @task, 0), actor)
    end

    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(-1, actor)
    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(child, nil)
  end

  test "unreadable child or source cannot be accessed through supplied structs", %{actor: actor} do
    %{user: stranger} = user_fixture()
    source = source!(actor)
    child = child!(source, actor)
    forged = %{child | owner_id: stranger.id}
    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(forged, stranger)

    assert {:error, :fork_context_unavailable} =
             ForkHistory.effective_branch(forged, nil, stranger)

    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(source.chat, stranger)
  end

  test "sharing a child alone does not share its private source", %{actor: actor} do
    %{user: reader} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [actor, reader]})
    configuration = configuration!(actor)
    bot = create!(Bot, :create, %{name: "Shared fork bot", first_messages: []}, actor)
    source = source!(actor, chat_attrs: %{bot_id: bot.id, llm_configuration_id: configuration.id})
    child = child!(source, actor)
    share!(child, group, actor)
    assert Ash.get!(Chat, child.id, actor: reader).id == child.id
    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(child.id, reader)

    assert {:error, :fork_context_unavailable} =
             ForkHistory.effective_branch(child.id, nil, reader)

    source_share = share!(source.chat, group, actor)
    assert {:ok, shared_history} = ForkHistory.prefix(child.id, reader)
    assert Enum.map(shared_history, & &1.id) == [source.root.id, source.message.id]
    Ash.destroy!(source_share, actor: actor)
    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(child.id, reader)
  end

  test "unfinished provider response is not promoted to a completed fork boundary", %{
    actor: actor
  } do
    source = source!(actor)
    child = child!(source, actor)
    update!(source.step, :update, %{response_final: false}, actor)
    assert {:error, :fork_context_unavailable} = ForkHistory.prefix(child, actor)

    assert_raise ArgumentError, ~r/fork_context_unavailable/, fn ->
      Context.history_for_generation!(child.id, actor: actor, parent_id: nil)
    end

    assert Threads.all_messages(child.id, actor) == []
  end

  test "ordinary and legacy copied fork histories are unchanged", %{actor: actor} do
    source = source!(actor)
    ordinary = source.chat

    legacy =
      create_chat!(
        Map.drop(link_attrs(source, @task, 0), [:fork_source_step_id, :fork_task]),
        actor
      )

    {:ok, copied} =
      Threads.add_message(legacy, :user, "Existing copied history", actor: actor, parent_id: nil)

    for {chat, target} <- [{ordinary, source.root.id}, {legacy, copied.id}] do
      assert {:ok, []} = ForkHistory.prefix(chat, actor)
      assert {:ok, []} = ForkHistory.effective_branch(chat, nil, actor)

      assert ForkHistory.effective_branch(chat, target, actor, load: @load, strict?: true) ==
               Threads.branch_to_message(chat, target, actor, load: @load, strict?: true)

      assert {:error, :message_not_found} = ForkHistory.effective_branch(chat, -1, actor)
    end

    assert Context.history_for_generation!(legacy.id, actor: actor) == [
             %{role: :user, content: "Existing copied history"}
           ]

    assert Context.history_for_generation!(ordinary.id, actor: actor, parent_id: nil) == []
  end

  test "canonical and provider raw call shapes keep matching results", %{actor: actor} do
    shapes = [
      %{
        "tool_call_id" => "canonical",
        "name" => "agent__fork",
        "arguments" => %{"task" => @task}
      },
      %{
        "raw" => %{
          "id" => "chat-call",
          "type" => "function",
          "function" => %{
            "name" => "agent__fork",
            "arguments" => Jason.encode!(%{"task" => @task})
          }
        }
      },
      %{
        "responses_item" => %{
          "id" => "fc-1",
          "type" => "function_call",
          "call_id" => "responses-call",
          "name" => "agent__fork",
          "arguments" => Jason.encode!(%{"task" => @task})
        }
      },
      %{"name" => "agent__fork", "arguments" => "invalid json"}
    ]

    for shape <- shapes do
      source = source!(actor)
      [call] = source.calls
      update_content!(call, :opaque, %{content_json: shape}, actor)
      child = child!(source, actor)
      [persisted_call] = Persistence.load_step_for_followup!(source.step.id).tool_calls
      assert {:ok, [_, boundary]} = ForkHistory.prefix(child, actor)
      step = hd(boundary.steps)
      projected_call = Enum.find(step.items, &(&1.type == :tool_call))
      assert History.opaque_payloads(projected_call) == [shape]
      result = Enum.find(step.items, &(&1.type == :tool_result))
      [opaque] = History.opaque_payloads(result)
      assert opaque["tool_call_id"] == persisted_call.call_id
      assert opaque["name"] == persisted_call.name
      assert opaque["raw"] == %{"fork_instruction" => %{"subagent" => true, "task" => @task}}
    end
  end

  defp source!(actor, opts \\ []) do
    chat =
      Keyword.get_lazy(opts, :chat, fn ->
        create_chat!(Keyword.get(opts, :chat_attrs, %{}), actor)
      end)

    {:ok, root} =
      Threads.add_message(chat, :user, Keyword.get(opts, :root_text, "Root question"),
        actor: actor,
        parent_id: nil
      )

    message =
      create!(
        ChatMessage,
        :add_message,
        %{
          chat_id: chat.id,
          parent_id: root.id,
          role: :assistant,
          status: :generating,
          llm_configuration_id: chat.llm_configuration_id
        },
        actor
      )

    sequence = if Keyword.get(opts, :previous_step?, false), do: 2, else: 1

    if sequence == 2 do
      previous = step!(message, 1, actor)
      item!(previous, 1, :answer, "Earlier completed step", actor)
    end

    step =
      step!(message, sequence, actor, %{status: :waiting_tools, input_tokens: 7, output_tokens: 3})

    item!(step, 5, :reasoning, "Parent reasoning", actor)
    answer = item!(step, 10, :answer, "Parent completed response", actor)

    calls =
      for number <- 1..Keyword.get(opts, :call_count, 1) do
        raw = %{
          "id" => "fc-#{number}",
          "type" => "function_call",
          "call_id" => "call-#{number}",
          "name" => "agent__fork",
          "arguments" => Jason.encode!(%{"task" => @task})
        }

        item!(step, 20 + number, :tool_call, "Fork call #{number}", actor, %{
          "tool_call_id" => "call-#{number}",
          "name" => "agent__fork",
          "raw" => raw
        })
      end

    %{chat: chat, root: root, message: message, step: step, calls: calls, answer: answer}
  end

  defp child!(source, actor, opts \\ []) do
    attrs =
      link_attrs(source, Keyword.get(opts, :task, @task), Keyword.get(opts, :selected_index, 0))

    create_chat!(
      Map.merge(attrs, %{
        bot_id: source.chat.bot_id,
        llm_configuration_id: source.chat.llm_configuration_id
      }),
      actor
    )
  end

  defp link_attrs(source, task, selected_index) do
    %{
      parent_chat_id: source.chat.id,
      parent_message_id: source.message.id,
      parent_tool_call_item_id: Enum.at(source.calls, selected_index).id,
      parent_relation_kind: :fork,
      subagent: true,
      fork_source_step_id: source.step.id,
      fork_task: task
    }
  end

  defp create_chat!(attrs, actor) do
    {internal, public} = Map.split(attrs, [:fork_source_step_id, :fork_task])

    Chat
    |> Ash.Changeset.for_create(:create_empty, public, actor: actor)
    |> Ash.Changeset.force_change_attributes(internal)
    |> Ash.create!(actor: actor)
  end

  defp update_chat!(chat, attrs, actor) do
    {internal, public} = Map.split(attrs, [:fork_source_step_id, :fork_task])

    chat
    |> Ash.Changeset.for_update(:update, public, actor: actor)
    |> Ash.Changeset.force_change_attributes(internal)
    |> Ash.update!(actor: actor)
  end

  defp step!(message, sequence, actor, attrs \\ %{}) do
    create!(
      ChatMessageStep,
      :create,
      Map.merge(
        %{
          chat_message_id: message.id,
          sequence: sequence,
          status: :done,
          response_final: true,
          raw_request: %{"model" => "test", "input" => []},
          raw_response: %{"id" => "parent-response", "output" => []}
        },
        attrs
      ),
      actor
    )
    |> Ash.load!([:raw_request, :raw_response], actor: actor)
  end

  defp item!(step, sequence, type, text, actor, opaque \\ nil, call_id \\ nil) do
    item =
      create!(
        ChatMessageItem,
        :create,
        %{
          chat_message_step_id: step.id,
          sequence: sequence,
          type: type,
          tool_call_item_id: call_id
        },
        actor
      )

    create!(
      ChatMessageContent,
      :create,
      %{chat_message_item_id: item.id, sequence: 1, kind: :text, content_text: text},
      actor
    )

    if opaque,
      do:
        create!(
          ChatMessageContent,
          :create,
          %{chat_message_item_id: item.id, sequence: 2, kind: :opaque, content_json: opaque},
          actor
        )

    Ash.load!(item, [:contents], actor: actor)
  end

  defp update_message_text!(message, text, actor) do
    loaded = Ash.load!(message, @load, actor: actor)
    item = loaded.steps |> hd() |> Map.fetch!(:items) |> hd()
    update_content!(item, :text, %{content_text: text}, actor)
  end

  defp corrupt_anchor!(chat, attrs, actor) do
    ForkHistoryCorruptFixture
    |> Ash.get!(chat.id, actor: actor, domain: IntellectualClub.Chat.ForkHistoryFixtureDomain)
    |> Ash.Changeset.for_update(:corrupt_anchor, attrs,
      actor: actor,
      domain: IntellectualClub.Chat
    )
    |> Ash.update!(actor: actor, domain: IntellectualClub.Chat.ForkHistoryFixtureDomain)

    Ash.get!(Chat, chat.id, actor: actor)
  end

  defp update_content!(item, kind, attrs, actor) do
    item = Ash.load!(item, [:contents], actor: actor)
    content = Enum.find(item.contents, &(&1.kind == kind))
    update!(content, :update, attrs, actor)
  end

  defp configuration!(actor) do
    provider =
      create!(
        LlmProvider,
        :create,
        %{
          name: "Fork history provider",
          type: :responses,
          base_url: "https://example.invalid/v1",
          api_key: "test-only"
        },
        actor
      )

    create!(
      LlmConfiguration,
      :create,
      %{
        provider_id: provider.id,
        model_name: "test-model",
        parameters: %{},
        enabled: true,
        supports_cache_control: false,
        supports_image_input: false
      },
      actor
    )
  end

  defp share!(chat, group, actor) do
    create!(
      ChatShare,
      :create,
      %{
        chat_id: chat.id,
        user_group_id: group.id,
        bot_id: chat.bot_id,
        llm_configuration_id: chat.llm_configuration_id
      },
      actor
    )
  end

  defp trace_snapshot(%{steps: steps} = message) do
    steps =
      steps
      |> Enum.sort_by(& &1.sequence)
      |> Enum.map(fn step ->
        items =
          step.items
          |> Enum.sort_by(& &1.sequence)
          |> Enum.map(
            &%{&1 | contents: Enum.sort_by(&1.contents, fn content -> content.sequence end)}
          )

        %{step | items: items}
      end)

    %{message | steps: steps}
  end

  defp trace_counts(actor) do
    Enum.map(
      [ChatMessage, ChatMessageStep, ChatMessageItem, ChatMessageContent],
      &Ash.count!(&1, actor: actor)
    )
  end

  defp create!(resource, action, attrs, actor) do
    resource |> Ash.Changeset.for_create(action, attrs, actor: actor) |> Ash.create!(actor: actor)
  end

  defp update!(record, action, attrs, actor) do
    record |> Ash.Changeset.for_update(action, attrs, actor: actor) |> Ash.update!(actor: actor)
  end
end
