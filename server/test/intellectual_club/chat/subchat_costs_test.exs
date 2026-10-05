defmodule IntellectualClub.Chat.SubchatCostsTest do
  use IntellectualClub.DataCase, async: false
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.SubchatCosts
  alias IntellectualClub.Chat.SubchatCostCache
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeTrace

  setup do
    if is_nil(Process.whereis(SubchatCostCache)), do: start_supervised!(SubchatCostCache)
    :ok
  end

  test "aggregates direct subchat and descendant usage by source message" do
    %{user: actor} = user_fixture()
    provider = create_provider!(actor)

    configuration =
      create_configuration!(actor, provider: provider, model_name: "subchat-cost-model")

    root = create_chat!(actor, llm_configuration_id: configuration.id)

    {:ok, source_one} = Threads.add_message_to_end(root, :user, "First", actor: actor)
    {:ok, source_two} = Threads.add_message_to_end(root, :assistant, "Second", actor: actor)
    {:ok, source_zero} = Threads.add_message_to_end(root, :user, "Zero", actor: actor)

    fork =
      create_chat!(actor,
        llm_configuration_id: configuration.id,
        parent_chat_id: root.id,
        parent_message_id: source_one.id,
        parent_relation_kind: :fork,
        subagent: true
      )

    handoff =
      create_chat!(actor,
        llm_configuration_id: configuration.id,
        parent_chat_id: fork.id,
        parent_message_id: persist_cost!(fork, configuration, actor, 0.01).id,
        parent_relation_kind: :handoff,
        subagent: true
      )

    nested_spawn =
      create_chat!(actor,
        llm_configuration_id: configuration.id,
        parent_chat_id: handoff.id,
        parent_message_id: persist_cost!(handoff, configuration, actor, 0.02).id,
        parent_relation_kind: :spawn,
        subagent: true
      )

    _nested_message = persist_cost!(nested_spawn, configuration, actor, 0.03)

    direct_spawn =
      create_chat!(actor,
        llm_configuration_id: configuration.id,
        parent_chat_id: root.id,
        parent_message_id: source_two.id,
        parent_relation_kind: :spawn,
        subagent: true
      )

    _direct_spawn_message = persist_cost!(direct_spawn, configuration, actor, 0.04)

    zero_spawn =
      create_chat!(actor,
        llm_configuration_id: configuration.id,
        parent_chat_id: root.id,
        parent_message_id: source_zero.id,
        parent_relation_kind: :spawn,
        subagent: true
      )

    direct_handoff =
      create_chat!(actor,
        llm_configuration_id: configuration.id,
        parent_chat_id: root.id,
        parent_message_id: source_one.id,
        parent_relation_kind: :handoff,
        subagent: false
      )

    _excluded_message = persist_cost!(direct_handoff, configuration, actor, 0.5)

    before_zero = SubchatCosts.summary(root.id, actor)
    _zero_message = persist_cost!(zero_spawn, configuration, actor, 0.0)
    after_zero = SubchatCosts.summary(root.id, actor, refresh?: true)

    assert_in_delta after_zero.costs_by_message_id[source_one.id], 0.06, 0.000_001
    assert_in_delta after_zero.costs_by_message_id[source_two.id], 0.04, 0.000_001
    assert after_zero.costs_by_message_id[source_zero.id] == 0.0
    assert before_zero.costs_by_message_id[source_zero.id] == nil
    assert before_zero.revision != after_zero.revision
  end

  defp persist_cost!(chat, configuration, actor, cost) do
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Prompt", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{
          chat_id: chat.id,
          parent_id: user_message.id,
          llm_configuration_id: configuration.id,
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    step_id =
      Persistence.ensure_step_started!(
        assistant_message.id,
        1,
        %{"model" => configuration.model_name},
        []
      )

    runtime_step =
      RuntimeTrace.new_step(
        id: step_id,
        sequence: 1,
        raw_request: %{"model" => configuration.model_name}
      )
      |> RuntimeTrace.apply_event(
        {:set_step_usage, %{input_tokens: 10, output_tokens: 5, cost: cost}}
      )
      |> RuntimeTrace.apply_event({:ensure_item, "answer", :answer, 1})
      |> RuntimeTrace.apply_event({:set_text, "answer", :answer, 1, "Done"})

    :ok = Persistence.persist_completed!(assistant_message.id, runtime_step)
    assistant_message
  end
end
