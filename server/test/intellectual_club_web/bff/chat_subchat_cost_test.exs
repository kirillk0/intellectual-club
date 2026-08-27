defmodule IntellectualClubWeb.Bff.ChatSubchatCostTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider

  test "chat state combines message and recursive subchat cost and updates idle revision", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)
    provider = create_provider!(actor)
    configuration = create_configuration!(actor, provider)
    root = create_chat!(actor, configuration)
    source_message = persist_cost!(root, configuration, actor, 0.01)

    child =
      create_chat!(actor, configuration, %{
        parent_chat_id: root.id,
        parent_message_id: source_message.id,
        parent_relation_kind: :fork,
        subagent: true
      })

    initial_state =
      conn
      |> get(~p"/api/bff/chat-state/#{root.id}")
      |> json_response(200)

    initial_source = branch_message(initial_state, source_message.id)
    assert initial_source["usage"]["total_cost"] == 0.01
    assert initial_source["usage"]["subchat_cost"] == nil
    assert initial_source["usage"]["combined_total_cost"] == 0.01

    _child_message = persist_cost!(child, configuration, actor, 0.02)

    changed_idle =
      conn
      |> get(
        ~p"/api/bff/chat-state/#{root.id}/idle-state?revision=#{initial_state["idle_revision"]}"
      )
      |> json_response(200)

    changed_state =
      conn
      |> get(~p"/api/bff/chat-state/#{root.id}")
      |> json_response(200)

    changed_source = branch_message(changed_state, source_message.id)
    assert changed_source["usage"]["total_cost"] == 0.01
    assert changed_source["usage"]["subchat_cost"] == 0.02
    assert changed_source["usage"]["combined_total_cost"] == 0.03
    assert changed_idle["revision"] != initial_state["idle_revision"]
    assert changed_state["idle_revision"] == changed_idle["revision"]
  end

  defp branch_message(payload, message_id) do
    Enum.find(payload["branch"], &(&1["id"] == message_id))
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
        name: "BFF subchat cost provider",
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
        model_name: "bff-subchat-cost-model",
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
