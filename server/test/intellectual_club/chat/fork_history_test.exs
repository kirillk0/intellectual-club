defmodule IntellectualClub.Chat.ForkHistoryTest do
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Chat.ForkFixtures

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageContent, ChatMessageItem}
  alias IntellectualClub.Chat.{ChatMessageStep, ForkBoundary, ForkHistory, ForkHistoryRevision}
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.SqlCapture
  alias IntellectualClub.Generation.{Context, History, Persistence, ToolCall}
  alias IntellectualClub.Llm.Providers.AnthropicMessages.Payload, as: AnthropicPayload
  alias IntellectualClub.Llm.Providers.Common.ChatHistory
  alias IntellectualClub.Llm.Providers.GoogleInteractions.Payload, as: GooglePayload
  alias IntellectualClub.Llm.Providers.Responses.HistoryInput

  @load [steps: [:raw_request, :raw_response, items: [contents: [:file]]]]
  @task IntellectualClub.Chat.ForkFixtures.fork_task()
  @selected_text "Fork branch initialized. The parent response is complete; follow only the next user instruction."
  @skipped_text "Skipped in this forked branch because this call is unrelated to the selected subagent task. Do not retry it."
  @anchor_fields [
    :parent_chat_id,
    :parent_message_id,
    :parent_tool_call_item_id,
    :parent_relation_kind,
    :subagent,
    :fork_source_step_id,
    :fork_task
  ]

  setup do
    %{user: actor} = user_fixture()
    %{actor: actor}
  end

  describe "boundary projection" do
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

    test "a single call keeps earlier history and substitutes only the boundary", %{actor: actor} do
      source = create_fork_source!(actor, previous_step?: true)
      child = create_fork_child!(actor, source)
      step = source.step
      placement = &%{"placement" => &1}

      before =
        create_opaque_item!(actor, step, "Before response", placement.("before_response"),
          sequence: 1,
          type: :steering
        )

      create_opaque_item!(actor, step, "PRIVATE REAL RESULT", %{"raw" => %{"private" => true}},
        sequence: 100,
        type: :tool_result,
        tool_call_item_id: source.call.id
      )

      create_text_item!(actor, step, "PRIVATE ARTIFACT", sequence: 101, type: :artifact)

      create_opaque_item!(actor, step, "LATER PARENT TASK", placement.("after_response"),
        sequence: 102,
        type: :steering
      )

      create_text_item!(actor, step, "LEGACY LATER STEERING", sequence: 103, type: :steering)
      create_text_item!(actor, step, "LATER PARENT ERROR", sequence: 104, type: :error)
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
      assert result.tool_call_item_id == source.call.id
      assert History.item_text(result) == @selected_text
      assert History.item_text(List.last(step.items)) == ForkBoundary.steering(@task)

      for private <- ["PRIVATE REAL RESULT", "PRIVATE ARTIFACT", "LATER PARENT", "LEGACY LATER"] do
        refute inspect(boundary) =~ private
      end

      persisted_after = Ash.get!(ChatMessage, source.message.id, actor: actor, load: @load)
      assert trace_snapshot(persisted_after) == trace_snapshot(persisted_before)
      assert trace_counts(actor) == counts
      assert Threads.all_messages(child.id, actor) == []
    end

    test "parallel results pair every call and project to every current provider format", %{
      actor: actor
    } do
      source = create_fork_source!(actor, call_count: 3)
      # Mixed shapes: the last call also carries canonical (already decoded) arguments.
      last = Enum.find(List.last(source.calls).contents, &(&1.kind == :opaque))
      canonical = Map.put(last.content_json, "arguments", %{"task" => @task})
      update_record!(actor, last, %{content_json: canonical})
      child = create_fork_child!(actor, source, selected_index: 1)
      assert {:ok, history} = ForkHistory.prefix(child.id, actor)
      step = history |> List.last() |> Map.fetch!(:steps) |> List.last()
      result_items = Enum.filter(step.items, &(&1.type == :tool_result))
      assert Enum.map(result_items, & &1.tool_call_item_id) == Enum.map(source.calls, & &1.id)
      expected_outputs = [@skipped_text, @selected_text, @skipped_text]
      assert Enum.map(result_items, &History.item_text/1) == expected_outputs

      [skipped, selected, _] = Enum.map(result_items, &(History.opaque_payloads(&1) |> hd()))
      assert selected["raw"] == %{"fork_instruction" => %{"subagent" => true, "task" => @task}}
      assert skipped["raw"]["fork_skipped"]["selected_tool_call_id"] == "call-2"

      assert selected["responses_item"] == %{
               "type" => "function_call_output",
               "call_id" => "call-2",
               "output" => @selected_text
             }

      call_ids = ["call-1", "call-2", "call-3"]
      responses = HistoryInput.build_input_items(history)
      calls = Enum.filter(responses, &(&1["type"] == "function_call"))
      assert Enum.map(calls, & &1["call_id"]) == call_ids
      outputs = Enum.filter(responses, &(&1["type"] == "function_call_output"))
      assert Enum.map(outputs, & &1["call_id"]) == call_ids
      assert Enum.map(outputs, & &1["output"]) == expected_outputs

      assert List.last(responses)["content"] == [
               %{"type" => "input_text", "text" => ForkBoundary.steering(@task)}
             ]

      messages = ChatHistory.build_messages(history)
      tools = Enum.filter(messages, &(&1["role"] == "tool"))
      assert Enum.map(tools, & &1["tool_call_id"]) == call_ids
      assert Enum.map(tools, & &1["content"]) == expected_outputs
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
        source = create_fork_source!(actor)
        update_record!(actor, source.call_content, %{content_json: shape})
        child = create_fork_child!(actor, source)
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

    test "stored unavailable functions are announced in reconstructed steering", %{actor: actor} do
      names = ["agent__fork", "agent__handoff"]
      source = create_fork_source!(actor)
      child = create_fork_child!(actor, source, unavailable_functions: names)
      assert {:ok, history} = ForkHistory.prefix(child, actor)

      steering = List.last(history) |> History.project_text_for_item_type(:steering)
      assert steering == ForkBoundary.steering(@task, names)
      assert steering =~ "every call fails, so do not call them and complete the task yourself: "
      assert steering =~ "`agent__fork`, `agent__handoff`.\n\nTask:\n#{@task}"
      assert String.ends_with?(steering, "\n\nTask:\n#{@task}")
      assert ForkBoundary.steering(@task, []) == ForkBoundary.steering(@task)

      error =
        assert_raise Ash.Error.Invalid, fn ->
          force_update!(actor, child, %{fork_unavailable_functions: ["agent__spawn"]})
        end

      assert Exception.message(error) =~ "cannot change a live fork source"
    end
  end

  describe "generation context" do
    test "a prepared prefix is published as prepared despite a later source edit", %{
      actor: actor
    } do
      source = create_fork_source!(actor)
      child = create_fork_child!(actor, source)
      assert {:ok, preparation} = Context.prepare(child.id, actor: actor)
      assert preparation.parent_id == nil
      assert Enum.any?(preparation.context.history, &(&1.content =~ "Parent completed response"))

      update_record!(actor, hd(source.answer.contents), %{content_text: "Edited parent response"})

      context = Context.publish!(preparation, actor: actor)
      assert context.history == preparation.context.history
      assert context.request_payload == preparation.context.request_payload
      assert context.parent_message_id == nil
      assert context.chat_id == child.id
      refute Enum.any?(context.history, &String.contains?(&1.content, "Edited parent response"))
    end

    test "history modes keep the boundary and select inherited opaque by configuration", %{
      actor: actor
    } do
      bot = create_bot!(actor, history_mode: :full)
      configuration = responses_configuration!(actor)

      source =
        create_fork_source!(actor,
          chat_attrs: %{bot_id: bot.id, llm_configuration_id: configuration.id}
        )

      create_opaque_item!(
        actor,
        source.step,
        "Summary",
        %{"type" => "reasoning", "encrypted_content" => "fork-encrypted", "summary" => []},
        sequence: 6,
        type: :reasoning
      )

      later = create_step!(actor, source.message, sequence: 2, response_final: true)
      create_text_item!(actor, later, "After fork boundary")
      child = create_fork_child!(actor, source)

      for mode <- [:full, :agent, :chat] do
        update_record!(actor, %Bot{id: bot.id}, %{history_mode: mode})
        assert {:ok, preparation} = Context.prepare(child.id, actor: actor, parent_id: nil)
        payload = inspect(preparation.context.request_payload)
        assert String.contains?(payload, "fork-encrypted") == (mode == :full)
        assert String.contains?(payload, @selected_text) == (mode != :chat)
        assert payload =~ "FORK CONTROL MESSAGE"
        assert payload =~ "Parent completed response"
        refute payload =~ "After fork boundary"
      end
    end

    test "first generation and followups use the inherited prefix plus the selected local branch",
         %{actor: actor} do
      configuration = responses_configuration!(actor)
      source = create_fork_source!(actor, chat_attrs: %{llm_configuration_id: configuration.id})
      child = create_fork_child!(actor, source)
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
      create_text_item!(actor, step, "Own completed answer")
      update_record!(actor, step, %{status: :done, response_final: true})
      set_message_status!(actor, local, :done)

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

    test "ordinary and legacy copied chats keep their own history and have no revision", %{
      actor: actor
    } do
      source = create_fork_source!(actor)
      ordinary = source.chat
      legacy = create_legacy_fork!(actor, source, %{parent_tool_call_item_id: source.call.id})

      {:ok, copied} =
        Threads.add_message(legacy, :user, "Existing copied history",
          actor: actor,
          parent_id: nil
        )

      for {chat, target} <- [{ordinary, source.root.id}, {legacy, copied.id}] do
        assert {:ok, []} = ForkHistory.prefix(chat, actor)
        assert {:ok, []} = ForkHistory.effective_branch(chat, nil, actor)

        assert ForkHistory.effective_branch(chat, target, actor, load: @load, strict?: true) ==
                 Threads.branch_to_message(chat, target, actor, load: @load, strict?: true)

        assert {:error, :message_not_found} = ForkHistory.effective_branch(chat, -1, actor)
        assert revision(chat, actor) == nil
        assert revision(chat.id, actor) == nil
      end

      assert Context.history_for_generation!(legacy.id, actor: actor) == [
               %{role: :user, content: "Existing copied history"}
             ]

      assert Context.history_for_generation!(ordinary.id, actor: actor, parent_id: nil) == []

      # A fork task alone marks a chat as linked; without a valid anchor it is unavailable.
      corrupt_chat!(actor, legacy, %{fork_task: @task})
      assert {:error, :fork_context_unavailable} = ForkHistory.prefix(legacy, actor)
      assert is_binary(revision(legacy, actor))
      assert revision(legacy.id, actor) == revision(legacy, actor)
    end
  end

  describe "live source" do
    test "source edits are live and change the revision without touching parent timestamps", %{
      actor: actor
    } do
      source = create_fork_source!(actor)
      child = create_fork_child!(actor, source)
      assert {:ok, original} = ForkHistory.prefix(child, actor)
      original_revision = revision(child, actor)
      parents = [source.chat, source.root, source.root_step, source.root_item]
      timestamps = Enum.map(parents, &updated_at(&1, actor))

      update_record!(actor, source.root_content, %{content_text: "Edited root"})
      edited_root = revision(child, actor)
      refute edited_root == original_revision
      assert Enum.map(parents, &updated_at(&1, actor)) == timestamps

      update_record!(actor, hd(source.answer.contents), %{content_text: "Edited boundary answer"})
      edited = revision(child, actor)
      refute edited in [original_revision, edited_root]
      update_record!(actor, child, %{note: "This must not replace the task"})
      assert revision(child, actor) == edited

      assert {:ok, [root, boundary] = current} = ForkHistory.prefix(child, actor)
      refute current == original
      assert History.project_user_input_text(root) == "Edited root"
      assert History.project_text_for_item_type(boundary, :answer) == "Edited boundary answer"

      assert History.project_text_for_item_type(boundary, :steering) ==
               ForkBoundary.steering(@task)
    end

    test "source continuation, siblings, statuses and execution metadata are not inherited", %{
      actor: actor
    } do
      source = create_fork_source!(actor, previous_step?: true)
      child = create_fork_child!(actor, source)
      assert {:ok, original} = ForkHistory.prefix(child, actor)
      original_revision = revision(child, actor)

      later = create_step!(actor, source.message, sequence: 3, response_final: true)
      create_text_item!(actor, later, "LATER SOURCE STEP")

      {:ok, _} =
        Threads.add_message(source.chat, :user, "LATER SOURCE MESSAGE",
          actor: actor,
          parent_id: source.message.id
        )

      {:ok, sibling} =
        Threads.add_message(source.chat, :assistant, "DIFFERENT ACTIVE BRANCH",
          actor: actor,
          parent_id: source.root.id
        )

      assert Ash.get!(Chat, source.chat.id, actor: actor).last_message_id == sibling.id
      assert ForkHistory.prefix(child, actor) == {:ok, original}
      assert revision(child, actor) == original_revision

      for {message_status, step_status} <- [
            generating: :waiting_tools,
            canceled: :canceled,
            error: :error,
            done: :done
          ] do
        update_record!(
          actor,
          source.message,
          %{status: message_status, error_detail: "Not history"},
          :set_generation_state
        )

        update_record!(actor, source.step, %{
          status: step_status,
          input_tokens: 999,
          output_tokens: 111,
          cost: 1.5,
          raw_response: %{"private" => "changed response"}
        })

        assert {:ok, [_, boundary]} = ForkHistory.prefix(child, actor)
        assert boundary.status == :done
        assert Enum.map(boundary.steps, & &1.status) == [:done, :done]
        history = Context.history_for_generation!(child.id, actor: actor, parent_id: nil)
        assert Enum.map(history, & &1.role) == [:user, :assistant]
        assert List.last(history).content =~ "Parent completed response"
        refute inspect(history) =~ "turn_aborted"
        assert revision(child, actor) == original_revision
      end

      update_record!(actor, source.previous, %{response_final: false, status: :error})
      update_record!(actor, source.chat, %{note: "Unrelated note"})
      assert revision(child, actor) == original_revision
    end

    test "nested forks inherit live anchored prefixes recursively", %{actor: actor} do
      source = create_fork_source!(actor)
      child = create_fork_child!(actor, source)
      inner = create_fork_source!(actor, chat: child, root_text: "Inner root")
      grandchild = create_fork_child!(actor, inner, task: "Inner task")
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

      child_revision = revision(child, actor)
      grandchild_revision = revision(grandchild, actor)

      # The child's own branch is its local tail: only descendants inherit it.
      update_record!(actor, inner.root_content, %{content_text: "Inner edit"})
      assert revision(child, actor) == child_revision
      inner_edit = revision(grandchild, actor)
      refute inner_edit == grandchild_revision

      update_record!(actor, source.root_content, %{content_text: "Live ancestor edit"})
      refute revision(child, actor) == child_revision
      refute revision(grandchild, actor) == inner_edit
      assert {:ok, [root | _]} = ForkHistory.prefix(grandchild, actor)
      assert History.project_user_input_text(root) == "Live ancestor edit"
    end

    test "inherited history is limited to 32 linked sources", %{actor: actor} do
      [previous, last] = actor |> create_fork_chain!(33) |> Enum.take(-2)
      assert {:ok, history} = ForkHistory.prefix(previous, actor)
      assert length(history) == 32
      assert {:error, :fork_context_unavailable} = ForkHistory.prefix(last, actor)
      too_deep = revision(last, actor)
      assert revision(last, actor) == too_deep

      # Unlinking the 32nd source brings the deepest fork back within the limit.
      corrupt_chat!(actor, previous, %{fork_source_step_id: nil, fork_task: nil})
      assert {:ok, [_boundary]} = ForkHistory.prefix(last, actor)
      refute revision(last, actor) == too_deep
    end
  end

  describe "access" do
    test "missing actors, forged structs and unreadable chats fail closed", %{actor: actor} do
      %{user: stranger} = user_fixture()
      source = create_fork_source!(actor)
      child = create_fork_child!(actor, source)
      forged = %{child | owner_id: stranger.id}
      unavailable = revision(-1, actor)
      assert is_binary(unavailable)

      for {chat, reader} <- [
            {forged, stranger},
            {source.chat, stranger},
            {child, nil},
            {-1, actor}
          ] do
        assert {:error, :fork_context_unavailable} = ForkHistory.prefix(chat, reader)
        assert revision(chat, reader) == unavailable
      end

      assert {:error, :fork_context_unavailable} =
               ForkHistory.effective_branch(forged, nil, stranger)

      assert revision(child, %{}) == unavailable
      assert revision(Integer.pow(10, 100), actor) == unavailable
    end

    test "sharing only a child never grants access to its private source", %{actor: actor} do
      %{user: reader} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [actor, reader]})
      configuration = responses_configuration!(actor)
      chat_attrs = %{bot_id: create_bot!(actor).id, llm_configuration_id: configuration.id}
      source = create_fork_source!(actor, chat_attrs: chat_attrs)
      child = create_fork_child!(actor, source)
      share_chat!(actor, child, group)
      assert Ash.get!(Chat, child.id, actor: reader).id == child.id
      assert {:error, :fork_context_unavailable} = ForkHistory.prefix(child.id, reader)

      assert {:error, :fork_context_unavailable} =
               ForkHistory.effective_branch(child.id, nil, reader)

      unavailable = revision(child, reader)
      assert is_binary(unavailable)
      refute unavailable == revision(child, actor)
      update_record!(actor, source.root_content, %{content_text: "Private edit"})
      assert revision(child, reader) == unavailable

      source_share = share_chat!(actor, source.chat, group)
      assert {:ok, shared_history} = ForkHistory.prefix(child.id, reader)
      assert Enum.map(shared_history, & &1.id) == [source.root.id, source.message.id]
      available = revision(child, reader)
      refute available == unavailable
      update_record!(actor, source.root_content, %{content_text: "Shared edit"})
      refute revision(child, reader) == available

      Ash.destroy!(source_share, actor: actor)
      assert {:error, :fork_context_unavailable} = ForkHistory.prefix(child.id, reader)
      assert revision(child, reader) == unavailable
    end
  end

  describe "unavailable history" do
    # {scenario, corruption, opts}; opts:
    #   sql_summary: true - the SQL source summary itself reports the source unavailable;
    #   revision_only: true - only the revision is checked while corrupted, because the
    #     ForkHistory branch walk (Threads.branch_to_message/4) has no message cycle guard.
    corruptions = [
      {"a chat cycle through a nested fork", :chat_cycle, []},
      {"a missing parent chat", :no_parent_chat, []},
      {"a parent message other than the anchor's", :root_parent_message, []},
      {"a missing selected call", :no_selected_call, []},
      {"a selected item that is not a tool call", :answer_selected, []},
      {"a missing source step", :no_source_step, []},
      {"a missing fork task", :no_fork_task, []},
      {"an anchor message in a foreign chat", :foreign_parent_chat, [sql_summary: true]},
      {"a message cycle above the boundary", :message_cycle,
       [sql_summary: true, revision_only: true]},
      {"a branch dangling into another chat", :dangling_branch, [sql_summary: true]},
      {"a non-assistant boundary message", :user_boundary, [sql_summary: true]},
      {"an unfinished provider response", :unfinished_response, [sql_summary: true]},
      {"a malformed selected call payload", :malformed_call, []}
    ]

    for {scenario, corruption, opts} <- corruptions do
      test "#{scenario} fails closed and recovers when repaired", %{actor: actor} do
        opts = unquote(opts)
        source = create_fork_source!(actor)
        child = create_fork_child!(actor, source)
        assert {:ok, prefix} = ForkHistory.prefix(child, actor)
        original = revision(child, actor)

        {restore, also_unavailable} = corrupt!(unquote(corruption), actor, source, child)

        unless Keyword.get(opts, :revision_only, false) do
          assert_prefix_unavailable(child, also_unavailable, actor)
        end

        {unavailable, capture} = SqlCapture.measure(fn -> revision(child, actor) end)
        refute unavailable == original
        assert revision(child, actor) == unavailable

        if Keyword.get(opts, :sql_summary, false) do
          assert [aggregate] =
                   Enum.filter(capture.queries, &String.starts_with?(&1.sql, "WITH RECURSIVE"))

          assert [[false, _digest]] = aggregate.rows
        end

        restore.()
        assert {:ok, restored} = ForkHistory.prefix(child, actor)
        assert Enum.map(restored, & &1.id) == Enum.map(prefix, & &1.id)
        assert revision(child, actor) == original
      end
    end
  end

  defp assert_prefix_unavailable(child, also_unavailable, actor) do
    for {chat, message_id} <- [{child, nil} | also_unavailable] do
      assert {:error, :fork_context_unavailable} = ForkHistory.prefix(chat, actor)

      assert {:error, :fork_context_unavailable} =
               ForkHistory.effective_branch(chat, message_id, actor)
    end

    # Generation fails before creating any local message.
    local = Threads.all_messages(child.id, actor)

    assert_raise ArgumentError, ~r/fork_context_unavailable/, fn ->
      Context.history_for_generation!(child.id, actor: actor, parent_id: nil)
    end

    assert Threads.all_messages(child.id, actor) == local
  end

  # Corrupts a linked fork and returns `{restore_fun, [{chat, message_id}]}`: the
  # function restores the original state, the list names further branches that
  # must be unavailable while corrupted.
  defp corrupt!(:chat_cycle, actor, source, child) do
    inner = create_fork_source!(actor, chat: child)
    corrupt_chat!(actor, source.chat, fork_link_attrs(inner))

    {fn -> corrupt_chat!(actor, source.chat, Map.take(source.chat, @anchor_fields)) end,
     [{source.chat, nil}, {child, inner.message.id}]}
  end

  defp corrupt!(:message_cycle, actor, source, _child),
    do: reparent_root!(actor, source, source.message.id)

  defp corrupt!(:dangling_branch, actor, source, _child) do
    other = create_message!(actor, create_empty_chat!(actor), %{role: :user})
    reparent_root!(actor, source, other.id)
  end

  defp corrupt!(:user_boundary, actor, source, _child) do
    boundary = force_update!(actor, source.message, %{role: :user}, :set_generation_state)
    {fn -> force_update!(actor, boundary, %{role: :assistant}, :set_generation_state) end, []}
  end

  defp corrupt!(:unfinished_response, actor, source, _child) do
    update_record!(actor, source.step, %{response_final: false})
    {fn -> update_record!(actor, source.step, %{response_final: true}) end, []}
  end

  defp corrupt!(:malformed_call, actor, source, _child) do
    original = Map.take(source.call_content, [:content_json, :updated_at])
    broken = update_record!(actor, source.call_content, %{content_json: %{"malformed" => true}})
    {fn -> force_update!(actor, broken, original) end, []}
  end

  defp corrupt!(anchor_corruption, actor, source, child) do
    attrs =
      case anchor_corruption do
        :no_parent_chat -> %{parent_chat_id: nil}
        :root_parent_message -> %{parent_message_id: source.root.id}
        :no_selected_call -> %{parent_tool_call_item_id: nil}
        :answer_selected -> %{parent_tool_call_item_id: source.answer.id}
        :no_source_step -> %{fork_source_step_id: nil}
        :no_fork_task -> %{fork_task: nil}
        :foreign_parent_chat -> %{parent_chat_id: create_empty_chat!(actor).id}
      end

    corrupt_chat!(actor, child, attrs)
    {fn -> corrupt_chat!(actor, child, fork_link_attrs(source)) end, []}
  end

  defp reparent_root!(actor, source, parent_id) do
    root = reparent_message!(actor, source.root, parent_id)
    {fn -> reparent_message!(actor, root, nil) end, []}
  end

  defp revision(chat, actor), do: ForkHistoryRevision.revision(chat, actor)

  defp updated_at(%resource{id: id}, actor), do: Ash.get!(resource, id, actor: actor).updated_at

  # No context length: generation contexts must not require one.
  defp responses_configuration!(actor) do
    create_configuration!(actor,
      model_name: "test-model",
      context_length: nil,
      provider_attrs: %{type: :responses, base_url: "https://example.invalid/v1"}
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
          |> Enum.map(&%{&1 | contents: Enum.sort_by(&1.contents, fn c -> c.sequence end)})

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
end
