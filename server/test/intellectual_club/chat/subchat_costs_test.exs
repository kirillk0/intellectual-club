defmodule IntellectualClub.Chat.SubchatCostsTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.SubchatCosts
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider

  test "aggregates direct subchat and descendant usage by source message" do
    %{user: actor} = user_fixture()
    provider = create_provider!(actor)
    configuration = create_configuration!(actor, provider)
    root = create_chat!(actor, configuration)

    {:ok, source_one} = Threads.add_message_to_end(root, :user, "First", actor: actor)
    {:ok, source_two} = Threads.add_message_to_end(root, :assistant, "Second", actor: actor)
    {:ok, source_zero} = Threads.add_message_to_end(root, :user, "Zero", actor: actor)

    fork =
      create_chat!(actor, configuration, %{
        parent_chat_id: root.id,
        parent_message_id: source_one.id,
        parent_relation_kind: :fork,
        subagent: true
      })

    handoff =
      create_chat!(actor, configuration, %{
        parent_chat_id: fork.id,
        parent_message_id: persist_cost!(fork, configuration, actor, 0.01).id,
        parent_relation_kind: :handoff,
        subagent: true
      })

    nested_spawn =
      create_chat!(actor, configuration, %{
        parent_chat_id: handoff.id,
        parent_message_id: persist_cost!(handoff, configuration, actor, 0.02).id,
        parent_relation_kind: :spawn,
        subagent: true
      })

    _nested_message = persist_cost!(nested_spawn, configuration, actor, 0.03)

    direct_spawn =
      create_chat!(actor, configuration, %{
        parent_chat_id: root.id,
        parent_message_id: source_two.id,
        parent_relation_kind: :spawn,
        subagent: true
      })

    _direct_spawn_message = persist_cost!(direct_spawn, configuration, actor, 0.04)

    zero_spawn =
      create_chat!(actor, configuration, %{
        parent_chat_id: root.id,
        parent_message_id: source_zero.id,
        parent_relation_kind: :spawn,
        subagent: true
      })

    direct_handoff =
      create_chat!(actor, configuration, %{
        parent_chat_id: root.id,
        parent_message_id: source_one.id,
        parent_relation_kind: :handoff,
        subagent: false
      })

    _excluded_message = persist_cost!(direct_handoff, configuration, actor, 0.5)

    before_zero = SubchatCosts.summary(root.id, actor)
    _zero_message = persist_cost!(zero_spawn, configuration, actor, 0.0)
    after_zero = SubchatCosts.summary(root.id, actor)

    assert_in_delta after_zero.costs_by_message_id[source_one.id], 0.06, 0.000_001
    assert_in_delta after_zero.costs_by_message_id[source_two.id], 0.04, 0.000_001
    assert after_zero.costs_by_message_id[source_zero.id] == 0.0
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

  defp create_chat!(actor, configuration, attrs \\ %{}) do
    attrs = Map.merge(%{note: "", llm_configuration_id: configuration.id}, attrs)

    Chat
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp create_provider!(actor) do
    LlmProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Subchat cost provider",
        type: :demo,
        auth_method: :api_key,
        base_url: nil,
        api_key: nil
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_configuration!(actor, provider) do
    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: "subchat-cost-model",
        note: "cfg",
        parameters: %{},
        enabled: true,
        timeout_seconds: 30,
        context_length: 2048,
        supports_cache_control: false,
        supports_image_input: false
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
