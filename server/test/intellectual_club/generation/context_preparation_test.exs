defmodule IntellectualClub.Generation.ContextPreparationTest do
  @moduledoc """
  Two-phase generation start (`Context.prepare/2` + `Context.publish!/2`), retry
  preparation (`Context.prepare_retry/2`) and spawn preparation.
  """

  use IntellectualClub.DataCase, async: false

  import IntellectualClub.SqlCapture, only: [capture_queries: 1, selects_from: 2, reading: 2]

  require Ash.Query

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageItem, ChatMessageStep}
  alias IntellectualClub.Chat.{LinkedForkCleanup, Spawn, Threads}
  alias IntellectualClub.Generation.{Context, Lease, Persistence, StepRequests}
  alias IntellectualClub.Generation.Context.{Preparation, StalePreparationError}
  alias IntellectualClub.Tools.{ExecutionContext, ToolInstance}

  describe "prepare/2 and publish!/2" do
    test "prepare is read-only and publish stores the final request exactly once" do
      %{user: actor} = user_fixture()
      {chat, root} = chat!(actor)
      before_messages = messages(chat.id, actor)

      {result, queries} = capture_queries(fn -> Context.prepare(chat.id, actor: actor) end)
      assert {:ok, %Preparation{} = preparation} = result
      assert preparation.context.message_id == nil
      assert preparation.context.step_id == nil
      assert messages(chat.id, actor) == before_messages
      refute Enum.any?(queries, &Regex.match?(~r/\b(INSERT|UPDATE|DELETE|FOR UPDATE)\b/, &1))
      refute Enum.any?(queries, &String.contains?(&1, "FOR NO KEY UPDATE"))
      refute Enum.any?(queries, &String.contains?(&1, ~s("raw_request")))
      refute Enum.any?(queries, &String.contains?(&1, ~s("raw_response")))

      {context, publication_queries} =
        capture_queries(fn -> Context.publish!(preparation, actor: actor) end)

      validation_queries =
        Enum.take_while(publication_queries, &(not String.starts_with?(&1, "INSERT")))

      for table <- ~w(chat_message_steps chat_message_items chat_message_contents
                      knowledge_blocks chat_knowledge_blocks bot_knowledge_blocks
                      user_knowledge_blocks llm_configuration_knowledge_blocks
                      chat_tool_bindings bot_tool_bindings bot_user_tool_bindings
                      tool_instances tool_functions secrets) do
        refute Enum.any?(validation_queries, &String.contains?(&1, ~s(FROM "#{table}")))
      end

      assert context.parent_message_id == root.id

      assert context.request_payload ==
               StepRequests.request_for_step!(context.step_id, actor: actor)

      assert context.messages ==
               context.adapter_module.request_snapshot(context.request_payload).model_input

      assert Ash.get!(ChatMessage, context.message_id, actor: actor).parent_id == root.id

      assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end
      assert length(messages(chat.id, actor)) == length(before_messages) + 1
    end

    test "pending user text is prepared exactly as it is published" do
      %{user: actor} = user_fixture()
      {chat, root} = chat!(actor)
      contents = [%{kind: :text, content_text: ""}, %{kind: :text, content_text: "Next question"}]

      assert {:ok, preparation} =
               Context.prepare(chat.id,
                 actor: actor,
                 parent_id: root.id,
                 pending_user_contents: contents
               )

      assert List.last(preparation.context.history) == %{role: :user, content: "Next question"}
      assert length(messages(chat.id, actor)) == 1

      context = Context.publish!(preparation, actor: actor)
      user = Ash.get!(ChatMessage, context.parent_message_id, actor: actor)
      assert user.role == :user
      assert user.parent_id == root.id
      assert Ash.get!(ChatMessage, context.message_id, actor: actor).parent_id == user.id

      assert List.last(Context.history_for_generation!(chat.id, actor: actor, parent_id: user.id)) ==
               List.last(preparation.context.history)
    end

    test "preparation and publication require the same authorized chat owner" do
      %{user: actor} = user_fixture()
      %{user: stranger} = user_fixture()
      {chat, _root} = chat!(actor)
      assert {:error, _reason} = Context.prepare(chat.id, actor: stranger)
      assert {:error, :forbidden} = Context.prepare(chat.id)
      assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)
      assert %{__exception__: true} = catch_error(Context.publish!(preparation, actor: stranger))
      assert length(messages(chat.id, actor)) == 1
    end

    test "unpublished media falls back while a spawn subchat can be prepared" do
      %{user: actor} = user_fixture()
      {chat, root} = chat!(actor)

      assert {:fallback, :pending_user_media} =
               Context.prepare(chat.id,
                 actor: actor,
                 pending_user_contents: [%{kind: :media, file_id: 123}]
               )

      {child, _root} =
        chat!(actor,
          parent_chat_id: chat.id,
          parent_message_id: root.id,
          parent_relation_kind: :spawn,
          subagent: true
        )

      assert {:ok, preparation} = Context.prepare(child.id, actor: actor)
      assert length(messages(child.id, actor)) == 1
      assert publish_snapshot!(preparation, actor).chat_id == child.id
    end

    test "dynamic prompt drivers are prepared without an input revision" do
      %{user: actor} = user_fixture()
      {chat, _root} = chat!(actor)

      tool = create_tool_instance!(actor, type: "native-knowledge-library", alias: "library")

      create_chat_tool_binding!(actor, chat, tool)
      assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)
      assert Map.has_key?(preparation.context.tool_instances_by_alias, "library")
      publish_snapshot!(preparation, actor)
    end

    test "inside an existing transaction prepare falls back to the protected build" do
      %{user: actor} = user_fixture()
      {chat, root} = chat!(actor)

      assert {:ok, context} =
               Ash.transaction(Chat, fn ->
                 assert {:fallback, :existing_transaction} =
                          Context.prepare(chat.id, actor: actor)

                 Context.build!(chat.id, actor: actor)
               end)

      assert context.parent_message_id == root.id
      assert length(messages(chat.id, actor)) == 2
    end
  end

  describe "publish!/2 consistency checks" do
    test "rejects a changed pending publication intent" do
      %{user: actor} = user_fixture()
      {chat, _root} = chat!(actor)

      assert {:ok, preparation} =
               Context.prepare(chat.id,
                 actor: actor,
                 pending_user_contents: [%{kind: :text, content_text: "Original"}]
               )

      changed = %{
        preparation
        | opts:
            Keyword.put(preparation.opts, :pending_user_contents, [
              %{kind: :text, content_text: "Changed"}
            ])
      }

      assert_raise StalePreparationError, fn -> Context.publish!(changed, actor: actor) end
      assert length(messages(chat.id, actor)) == 1
    end

    test "rolls back the pending user, assistant and active leaf when step publication fails" do
      %{user: actor} = user_fixture()
      {chat, root} = chat!(actor)

      assert {:ok, preparation} =
               Context.prepare(chat.id,
                 actor: actor,
                 pending_user_contents: [%{kind: :text, content_text: "Must roll back"}]
               )

      invalid = %{
        preparation
        | context: %{preparation.context | request_payload: %{"not_json" => self()}}
      }

      assert_raise Ash.Error.Invalid, ~r/invalid_json_value/, fn ->
        Context.publish!(invalid, actor: actor)
      end

      assert [%ChatMessage{id: id}] = messages(chat.id, actor)
      assert id == root.id
      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == root.id
    end

    test "rejects a preparation after a branch switch or a new message" do
      %{user: actor} = user_fixture()
      {chat, root} = chat!(actor)
      assert {:ok, preparation} = Context.prepare(chat.id, actor: actor, parent_id: root.id)
      {:ok, newer} = Threads.add_message_to_end(chat, :user, "Changed leaf", actor: actor)

      assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end
      assert length(messages(chat.id, actor)) == 2
      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == newer.id
    end

    test "keeps an explicit earlier parent independently of the observed active leaf" do
      %{user: actor} = user_fixture()
      {chat, root} = chat!(actor)
      {:ok, leaf} = Threads.add_message_to_end(chat, :user, "Other branch", actor: actor)
      assert {:ok, preparation} = Context.prepare(chat.id, actor: actor, parent_id: root.id)
      assert preparation.parent_id == root.id
      assert preparation.last_message_id == leaf.id

      context = publish_snapshot!(preparation, actor)
      assert context.parent_message_id == root.id
      assert List.last(context.history) == %{role: :user, content: "Question"}
    end

    test "rejects both parent fields rewritten to reattach the draft" do
      %{user: actor} = user_fixture()
      {chat, root} = chat!(actor)
      {:ok, leaf} = Threads.add_message_to_end(chat, :user, "Later message", actor: actor)

      for parent_opts <- [[], [parent_id: leaf.id]] do
        assert {:ok, preparation} = Context.prepare(chat.id, [actor: actor] ++ parent_opts)

        changed = %{
          preparation
          | parent_id: root.id,
            context: %{preparation.context | parent_message_id: root.id}
        }

        assert_raise StalePreparationError, fn -> Context.publish!(changed, actor: actor) end
      end

      assert length(messages(chat.id, actor)) == 2
      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == leaf.id
    end

    test "rejects a preparation whose explicit parent was removed" do
      %{user: actor} = user_fixture()
      {chat, root} = chat!(actor)
      assert {:ok, preparation} = Context.prepare(chat.id, actor: actor, parent_id: root.id)
      Ash.destroy!(root, actor: actor)
      assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end
      assert messages(chat.id, actor) == []
    end
  end

  describe "publish!/2 keeps the prepared snapshot across" do
    test "history content edits and trace membership changes" do
      %{user: actor} = user_fixture()
      {chat, root} = chat!(actor)
      root = Ash.get!(ChatMessage, root.id, actor: actor, load: [steps: [items: [:contents]]])
      [step] = root.steps
      [item] = step.items
      [content] = item.contents
      assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)

      content
      |> Ash.Changeset.for_update(:update, %{content_text: "Edited"}, actor: actor)
      |> Ash.update!(actor: actor)

      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        %{chat_message_step_id: step.id, sequence: 2, type: :input},
        actor: actor
      )
      |> Ash.create!(actor: actor)

      context = publish_snapshot!(preparation, actor)
      assert List.last(context.history) == %{role: :user, content: "Question"}
      assert length(messages(chat.id, actor)) == 2
    end

    test "knowledge block updates and binding insertion or removal" do
      %{user: actor} = user_fixture()

      for mutation <- [:insert, :update, :remove] do
        {chat, _root} = chat!(actor)
        block = create_knowledge_block!(actor, name: "Prompt", content: "Original prompt")
        binding = if mutation != :insert, do: create_chat_block_binding!(actor, chat, block)
        assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)

        case mutation do
          :insert ->
            create_chat_block_binding!(actor, chat, block)

          :update ->
            block
            |> Ash.Changeset.for_update(:update, %{content: "Changed prompt"}, actor: actor)
            |> Ash.update!(actor: actor)

          :remove ->
            Ash.destroy!(binding, actor: actor)
        end

        context = publish_snapshot!(preparation, actor)
        assert context.system_prompt == preparation.context.system_prompt
        refute context.system_prompt =~ "Changed prompt"
        assert context.system_prompt =~ "Original prompt" == (mutation != :insert)
      end
    end

    test "provider, configuration and chat setting updates" do
      %{user: actor} = user_fixture()

      provider = create_provider!(actor, type: :responses, base_url: "https://example.test")

      configuration =
        create_configuration!(actor, provider: provider, model_name: "model", context_length: nil)

      {chat, _root} = chat!(actor, llm_configuration_id: configuration.id)
      assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)

      configuration
      |> Ash.Changeset.for_update(:update, %{model_name: "different"}, actor: actor)
      |> Ash.update!(actor: actor)

      provider
      |> Ash.Changeset.for_update(:update, %{base_url: "https://changed.test"}, actor: actor)
      |> Ash.update!(actor: actor)

      chat
      |> Ash.Changeset.for_update(:update, %{llm_configuration_id: nil, note: "Changed settings"},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      context = publish_snapshot!(preparation, actor)
      assert context.llm_configuration_id == configuration.id
      assert context.model_name == "model"
      assert context.provider_base_url == "https://example.test"
    end

    test "tool binding insertion, removal and instance edits" do
      %{user: actor} = user_fixture()

      for mutation <- [:insert, :update, :remove] do
        {chat, _root} = chat!(actor)

        tool = create_tool_instance!(actor, type: "native-web-reader", alias: "reader")

        binding = if mutation != :insert, do: create_chat_tool_binding!(actor, chat, tool)
        assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)

        case mutation do
          :insert ->
            create_chat_tool_binding!(actor, chat, tool)

          :update ->
            tool
            |> Ash.Changeset.for_update(:update, %{description: "Changed tool context"},
              actor: actor
            )
            |> Ash.update!(actor: actor)

          :remove ->
            Ash.destroy!(binding, actor: actor)
        end

        context = publish_snapshot!(preparation, actor)
        assert context.tools_payload == preparation.context.tools_payload
        refute context.system_prompt =~ "Changed tool context"
        assert Map.has_key?(context.tool_instances_by_alias, "reader") == (mutation != :insert)
      end
    end
  end

  describe "prepare_retry/2" do
    for {selection, status, expected_sequence} <- [{:last, :error, 3}, {:requested, :done, 2}] do
      test "selects the #{selection} step and reads only its bounded request window" do
        %{user: actor} = user_fixture()
        chat = create_chat!(actor)
        {message, steps} = retryable_message!(actor, chat, unquote(status), 3)
        step = Enum.at(steps, unquote(expected_sequence) - 1)

        opts =
          case unquote(selection) do
            :last -> [actor: actor]
            :requested -> [actor: actor, step_id: step.id, allowed_statuses: [:done, :error]]
          end

        {result, queries} = capture_queries(fn -> Context.prepare_retry(message.id, opts) end)

        assert {:ok, context} = result
        assert context.step_id == step.id
        assert context.initial_step_sequence == unquote(expected_sequence)
        assert context.request_payload == retry_request(unquote(expected_sequence))
        assert context.request_payload == StepRequests.request_for_step!(step.id, actor: actor)
        assert_bounded_retry_request_queries(queries)
      end
    end

    test "reconstructs a patch step without hydrating or rewriting either step" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)
      {message, [first]} = retryable_message!(actor, chat, :error, 1)
      base = StepRequests.request_for_step!(first.id, actor: actor)
      request = Map.put(base, "temperature", 0.75)

      encoded =
        StepRequests.create_attributes(request,
          sequence: 2,
          previous_step: first,
          previous_request: base
        )

      assert encoded.request_mode == :patch
      second = create_step!(actor, message, Map.merge(encoded, %{sequence: 2, status: :error}))

      assert {:ok, context} = Context.prepare_retry(message.id, actor: actor)
      assert context.step_id == second.id
      assert context.request_payload == request

      saved =
        Ash.get!(ChatMessageStep, second.id,
          actor: actor,
          load: [:raw_request, :request_mode, :request_patch]
        )

      assert saved.raw_request == %{}
      assert saved.request_mode == :patch
      assert saved.request_patch == encoded.request_patch
      assert StepRequests.request_for_step!(first.id, actor: actor) == base
    end

    @tag :whitebox
    test "the retry replacement selects its step range in SQL without raw payloads" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)
      {message, [_step_1, _step_2, step_3]} = retryable_message!(actor, chat, :error, 3)
      request = StepRequests.request_for_step!(step_3.id, actor: actor)
      assert {:ok, reservation} = Lease.reserve(message.id)

      {claim, queries} =
        capture_queries(fn ->
          Lease.claim_and_run_with_chat(
            reservation,
            chat.id,
            [:error],
            fn operation, fenced ->
              Persistence.replace_steps_for_retry!(message.id, 3, request, [], operation,
                lease: fenced
              )
            end,
            with_lock_scope: fn callback ->
              LinkedForkCleanup.with_scope({:steps, message.id, 3}, actor, callback)
            end
          )
        end)

      assert {:ok, {fenced, new_step_id}} = claim
      assert :ok = Lease.release(fenced)

      assert [range_query | _] =
               queries
               |> selects_from("chat_message_steps")
               |> Enum.filter(&String.contains?(&1, ~s("sequence" >=)))

      refute range_query =~ ~s("raw_request")
      refute range_query =~ ~s("raw_response")

      replacement =
        ChatMessageStep
        |> Ash.Query.filter(id == ^new_step_id)
        |> Ash.Query.select([:id, :sequence, :status])
        |> Ash.read_one!(actor: actor)

      assert replacement.sequence == 3
      assert replacement.status == :waiting_provider
      assert StepRequests.request_for_step!(replacement.id, actor: actor) == request
    end
  end

  describe "Spawn.start_or_resume/6 preparation" do
    test "a nesting rejection precedes transaction authority and changes nothing" do
      %{user: actor} = user_fixture()
      source = create_subchat!(actor, create_empty_chat!(actor), :spawn)

      %{message: message, step: step, item: call} =
        create_tool_call_anchor!(actor, chat: source, message: %{token_count: 0})

      context = %ExecutionContext{
        owner_id: actor.id,
        chat_id: source.id,
        message_id: message.id,
        assistant_message_id: message.id,
        step_id: step.id,
        tool_call_item_id: call.id,
        generation_fence_token: Ash.UUID.generate()
      }

      tool = %ToolInstance{
        type: "native-agent-management",
        config: %{"nested_subchats_limit" => 0}
      }

      reason =
        "Nested subchat creation is unavailable for this subagent. " <>
          "Continue working on the task yourself without creating another subchat."

      for opts <- [[], [background_task_authority: :invalid]] do
        assert {:error, ^reason} =
                 Spawn.start_or_resume(tool, "Brief", "Task", context, actor, opts)
      end

      assert [] ==
               Chat |> Ash.Query.filter(parent_chat_id == ^source.id) |> Ash.read!(actor: actor)

      assert Ash.get!(ChatMessage, message.id, actor: actor).status == :done
      assert Ash.get!(Chat, source.id, actor: actor).last_message_id == message.id
    end
  end

  defp publish_snapshot!(preparation, actor) do
    context = Context.publish!(preparation, actor: actor)

    assert Map.take(context.request_payload, Map.keys(preparation.context.request_payload)) ==
             preparation.context.request_payload

    assert StepRequests.request_for_step!(context.step_id, actor: actor) ==
             context.request_payload

    context
  end

  defp chat!(actor, attrs \\ []) do
    chat = create_chat!(actor, attrs)
    {:ok, root} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)
    {chat, root}
  end

  defp messages(chat_id, actor), do: Threads.all_messages(chat_id, actor)

  defp retryable_message!(actor, chat, status, step_count) do
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

    message =
      create_message!(actor, chat,
        parent_id: user_message.id,
        status: status,
        error_detail: if(status == :error, do: "boom"),
        token_count: 0
      )

    steps =
      for sequence <- 1..step_count do
        create_step!(actor, message,
          sequence: sequence,
          status: status,
          raw_request: retry_request(sequence),
          raw_response: %{"step" => sequence},
          response_final: status == :done and sequence == step_count
        )
      end

    {message, steps}
  end

  defp retry_request(sequence) do
    %{
      "model" => "demo-model",
      "metadata" => %{"padding" => String.duplicate("x", 2_000)},
      "temperature" => 0,
      "reasoning" => %{"effort" => "low"},
      "messages" => [%{"role" => "user", "content" => "hello step #{sequence}"}],
      "stream" => true
    }
  end

  # The selected step is read without payloads, then exactly one query reads the
  # request columns of the bounded sequence window and none reads responses.
  defp assert_bounded_retry_request_queries(queries) do
    step_queries = selects_from(queries, "chat_message_steps")
    [selected_step | _] = step_queries
    refute selected_step =~ ~s("raw_request")
    refute selected_step =~ ~s("raw_response")

    assert [request_query] = reading(step_queries, "raw_request")
    assert request_query =~ ~s("request_patch")
    assert request_query =~ ~s("sequence" >=)
    assert request_query =~ ~s("sequence" <=)
    assert reading(step_queries, "raw_response") == []
  end
end
