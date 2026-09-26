defmodule IntellectualClub.Generation.ContextPreparationTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.{
    Chat,
    ChatKnowledgeBlock,
    ChatMessage,
    ChatMessageItem,
    Threads
  }

  alias IntellectualClub.Generation.Context
  alias IntellectualClub.Generation.Context.{Preparation, StalePreparationError}
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.{LlmConfiguration, LlmProvider}
  alias IntellectualClub.Tools.{ChatToolBinding, ToolInstance}

  test "preparation performs only authorized reads and publication stores the final request once" do
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

    refute Enum.any?(validation_queries, fn query ->
             String.contains?(query, ~s(FROM "chat_message_contents")) and
               (String.contains?(query, ~s("content_text")) or
                  String.contains?(query, ~s("content_json")))
           end)

    assert context.parent_message_id == root.id

    assert context.request_payload ==
             StepRequests.request_for_step!(context.step_id, actor: actor)

    assert context.messages ==
             context.adapter_module.request_snapshot(context.request_payload).model_input

    assert Ash.get!(ChatMessage, context.message_id, actor: actor).parent_id == root.id

    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end
    assert length(messages(chat.id, actor)) == length(before_messages) + 1
  end

  test "synthetic queued text is identical to the subsequently published canonical user input" do
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

  test "changing the pending publication intent invalidates its prepared request" do
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

  test "failed step publication rolls back the pending user, assistant, and active leaf" do
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

    assert_raise IntellectualClub.Generation.StepRequests.Error, fn ->
      Context.publish!(invalid, actor: actor)
    end

    assert [%ChatMessage{id: id}] = messages(chat.id, actor)
    assert id == root.id
    assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == root.id
  end

  test "a branch switch or new message invalidates a prepared request before insertion" do
    %{user: actor} = user_fixture()
    {chat, root} = chat!(actor)
    assert {:ok, preparation} = Context.prepare(chat.id, actor: actor, parent_id: root.id)
    {:ok, newer} = Threads.add_message_to_end(chat, :user, "Changed leaf", actor: actor)

    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end
    assert length(messages(chat.id, actor)) == 2
    assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == newer.id
  end

  test "history content edits and trace membership changes invalidate a snapshot without a leaf update" do
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

    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end

    assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)

    ChatMessageItem
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_step_id: step.id, sequence: 2, type: :input},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end
    assert length(messages(chat.id, actor)) == 1
  end

  test "prompt content updates and binding insertion or removal invalidate a snapshot" do
    %{user: actor} = user_fixture()
    {chat, _root} = chat!(actor)
    block = block!(actor)
    assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)
    binding = bind_block!(chat, block, actor)
    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end

    assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)

    block
    |> Ash.Changeset.for_update(:update, %{content: "Changed prompt"}, actor: actor)
    |> Ash.update!(actor: actor)

    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end

    assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)
    Ash.destroy!(binding, actor: actor)
    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end
  end

  test "provider and configuration updates invalidate a prepared request" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Prepared provider",
          type: :responses,
          base_url: "https://example.test",
          api_key: "key"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{provider_id: provider.id, model_name: "model"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {chat, _root} = chat!(actor, llm_configuration_id: configuration.id)
    assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)

    configuration
    |> Ash.Changeset.for_update(:update, %{model_name: "different"}, actor: actor)
    |> Ash.update!(actor: actor)

    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end

    assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)

    provider
    |> Ash.Changeset.for_update(:update, %{base_url: "https://changed.test"}, actor: actor)
    |> Ash.update!(actor: actor)

    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end
  end

  test "tool binding insertion and instance edits invalidate an ordinary snapshot" do
    %{user: actor} = user_fixture()
    {chat, _root} = chat!(actor)

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{type: "native-web-reader", name: "Reader", alias: "reader", config: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)

    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, tool_instance_id: tool.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end

    assert {:ok, preparation} = Context.prepare(chat.id, actor: actor)

    tool
    |> Ash.Changeset.for_update(:update, %{description: "Different tool context"}, actor: actor)
    |> Ash.update!(actor: actor)

    assert_raise StalePreparationError, fn -> Context.publish!(preparation, actor: actor) end
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

  test "unpublished media and related chat identity use explicit fallback without mutation" do
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

    assert {:fallback, :related_chat} = Context.prepare(child.id, actor: actor)
    assert length(messages(child.id, actor)) == 1
  end

  defp chat!(actor, attrs \\ []) do
    chat =
      Chat
      |> Ash.Changeset.for_create(:create, Map.new([note: ""] ++ attrs), actor: actor)
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)
    {chat, root}
  end

  defp messages(chat_id, actor), do: Threads.all_messages(chat_id, actor)

  defp block!(actor) do
    KnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{name: "Prompt", version: "v1", content: "Original prompt"},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp bind_block!(chat, block, actor) do
    ChatKnowledgeBlock
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, knowledge_block_id: block.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp capture_queries(fun) do
    handler = {__MODULE__, make_ref()}
    pid = self()

    :telemetry.attach_many(
      handler,
      [[:intellectual_club, :repo, :query], [:intellectual_club, :postgres_repo, :query]],
      fn _event, _measurements, metadata, target ->
        send(target, {:preparation_query, IO.iodata_to_binary(metadata.query)})
      end,
      pid
    )

    try do
      result = fun.()
      {result, drain_queries([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_queries(acc) do
    receive do
      {:preparation_query, query} -> drain_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
