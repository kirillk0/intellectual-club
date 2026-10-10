defmodule IntellectualClubWeb.Bff.ChatActivityTest do
  @moduledoc """
  Generation activity seen by the SPA: idle-state revisions, in-memory generation state, child chat activity and subchat cost snapshots.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.SubchatCostCache
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.LlmUsageRecord

  require Ash.Query

  describe "idle-state revisions" do
    for {scope, path} <- [
          {"chat list", "/api/bff/chat-list/idle-state"},
          {"chat state", "/api/bff/chat-state/:id/idle-state"}
        ] do
      test "#{scope} answers 204 while unchanged and a new revision after generation starts",
           %{conn: conn} do
        %{user: actor} = fixture = user_fixture()
        conn = sign_in_conn(conn, fixture)
        chat = create_chat!(actor)
        path = String.replace(unquote(path), ":id", "#{chat.id}")

        initial = conn |> get(path) |> json_response(200)
        assert is_binary(initial["revision"])
        assert initial["active_generation_message_id"] == nil
        assert conn |> get(path, revision: initial["revision"]) |> response(204) == ""

        generating = create_generating_message!(actor, chat)

        changed = conn |> get(path, revision: initial["revision"]) |> json_response(200)
        assert changed["revision"] != initial["revision"]
        assert changed["active_generation_message_id"] == generating.id
      end
    end

    test "chat state idle-state mirrors chat state access errors", %{conn: conn} do
      %{user: owner} = user_fixture()
      conn = sign_in_conn(conn, user_fixture())
      chat = create_chat!(owner)

      state_conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}")
      idle_conn = get(conn, ~p"/api/bff/chat-state/#{chat.id}/idle-state")

      assert idle_conn.status == state_conn.status

      assert json_response(idle_conn, idle_conn.status) ==
               json_response(state_conn, state_conn.status)
    end
  end

  describe "GET /api/bff/chat-list/generation-state" do
    test "reads owned workers from memory", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      %{user: other_actor} = user_fixture()
      conn = sign_in_conn(conn, fixture)
      chat = create_chat!(actor)
      message = create_generating_message!(actor, chat)
      other_chat = create_chat!(other_actor)
      other_message = create_generating_message!(other_actor, other_chat)

      for {owner, chat, message} <- [
            {actor, chat, message},
            {other_actor, other_chat, other_message}
          ],
          key <- [{:chat, chat.id}, {:message, message.id}] do
        {:ok, _owner} =
          Registry.register(IntellectualClub.Generation.Registry, key, %{
            chat_id: chat.id,
            message_id: message.id,
            owner_id: owner.id
          })
      end

      payload =
        conn
        |> get(~p"/api/bff/chat-list/generation-state", %{
          "chat_ids" => "#{chat.id},#{other_chat.id}",
          "message_ids" => "#{message.id},#{other_message.id}"
        })
        |> json_response(200)

      assert payload["chat_generations"] == [%{"chat_id" => chat.id, "message_id" => message.id}]
      assert payload["active_message_ids"] == [message.id]
    end

    test "keeps the original subchat active as generation moves through handoffs", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      conn = sign_in_conn(conn, fixture)
      parent = create_chat!(actor)
      child = create_subchat!(actor, parent, :spawn)
      source = create_generating_message!(actor, child, step: :waiting_provider)
      continuation = create_subchat!(actor, child, :handoff)
      continued = create_generating_message!(actor, continuation, step: :waiting_provider)
      create_handoff_result!(actor, source, continuation, continued)
      set_message_status!(actor, source, :done)

      params = %{"chat_ids" => "#{child.id}", "message_ids" => "#{source.id}"}
      payload = conn |> get(~p"/api/bff/chat-list/generation-state", params) |> json_response(200)

      assert payload["chat_generations"] == [
               %{"chat_id" => child.id, "message_id" => continued.id}
             ]

      terminal = create_subchat!(actor, continuation, :handoff)
      terminal_message = create_generating_message!(actor, terminal)
      create_handoff_result!(actor, continued, terminal, terminal_message)
      set_message_status!(actor, continued, :done)

      payload = conn |> get(~p"/api/bff/chat-list/generation-state", params) |> json_response(200)

      assert payload["chat_generations"] == [
               %{"chat_id" => child.id, "message_id" => terminal_message.id}
             ]

      foreign_conn = sign_in_conn(build_conn(), user_fixture())

      assert foreign_conn
             |> get(~p"/api/bff/chat-list/generation-state", params)
             |> json_response(200)
             |> Map.fetch!("chat_generations") == []

      set_message_status!(actor, terminal_message, :done)

      assert conn
             |> get(~p"/api/bff/chat-list/generation-state", params)
             |> json_response(200)
             |> Map.fetch!("chat_generations") == []
    end
  end

  describe "fork child activity" do
    setup %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      parent = create_chat!(actor)
      {:ok, parent_message} = Threads.add_message_to_end(parent, :user, "Delegate", actor: actor)

      %{
        conn: sign_in_conn(conn, fixture),
        actor: actor,
        parent: parent,
        parent_message: parent_message
      }
    end

    test "chat state relations and idle revisions follow generation status", ctx do
      %{conn: conn, actor: actor, parent: parent} = ctx
      initial_revision = idle_revision(conn, parent)
      child = create_fork_child!(ctx)
      {:ok, child_message} = Threads.add_message_to_end(child, :user, "Work", actor: actor)

      generating =
        create!(
          ChatMessage,
          :create_generating_assistant,
          %{chat_id: child.id, parent_id: child_message.id},
          actor
        )

      revision = assert_child_activity(ctx, child, initial_revision, generating.id, "generating")

      generating
      |> Ash.Changeset.for_update(
        :set_generation_state,
        %{status: :error, error_detail: "Provider failed"},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      assert_child_activity(ctx, child, revision, nil, "error")
    end

    test "a persisted handoff keeps the child active in list, summary, state and idle endpoints",
         ctx do
      %{conn: conn, actor: actor, parent: parent} = ctx
      initial_revision = idle_revision(conn, parent)
      child = create_fork_child!(ctx)
      source = create_generating_message!(actor, child, step: :waiting_provider)

      continuation =
        create_chat!(actor,
          parent_chat_id: child.id,
          parent_message_id: source.id,
          parent_relation_kind: :handoff,
          subagent: true
        )

      continued = create_generating_message!(actor, continuation, step: :waiting_provider)
      create_handoff_result!(actor, source, continuation, continued)
      set_message_status!(actor, source, :done)

      revision = assert_child_activity(ctx, child, initial_revision, continued.id, "generating")
      assert list_subchat(conn, parent, child)["active_generation_message_id"] == continued.id

      summary = conn |> get(~p"/api/bff/chat-list/#{child.id}/summary") |> json_response(200)
      assert summary["chat"]["active_generation_message_id"] == continued.id

      list_idle = conn |> get(~p"/api/bff/chat-list/idle-state") |> json_response(200)
      assert list_idle["active_generation_message_id"] == continued.id

      terminal = create_subchat!(actor, continuation, :handoff, parent_message_id: continued.id)
      terminal_message = create_generating_message!(actor, terminal)
      create_handoff_result!(actor, continued, terminal, terminal_message)
      set_message_status!(actor, continued, :done)

      revision = assert_child_activity(ctx, child, revision, terminal_message.id, "generating")

      child_state = conn |> get(~p"/api/bff/chat-state/#{child.id}") |> json_response(200)
      [relation] = child_state["relations"]["children_by_message_id"]["#{source.id}"]
      assert relation["active_generation_message_id"] == terminal_message.id
      assert relation["last_message_status"] == "generating"

      set_message_status!(actor, terminal_message, :canceled)

      assert_child_activity(ctx, child, revision, nil, "canceled")
      assert list_subchat(conn, parent, child)["active_generation_message_id"] == nil

      child_state = conn |> get(~p"/api/bff/chat-state/#{child.id}") |> json_response(200)
      [relation] = child_state["relations"]["children_by_message_id"]["#{source.id}"]
      assert relation["active_generation_message_id"] == nil
      assert relation["last_message_status"] == "canceled"

      settled_list_idle =
        conn
        |> get(~p"/api/bff/chat-list/idle-state", revision: list_idle["revision"])
        |> json_response(200)

      assert settled_list_idle["revision"] != list_idle["revision"]
      assert settled_list_idle["active_generation_message_id"] == nil
    end
  end

  describe "subchat cost snapshots" do
    setup do
      if is_nil(Process.whereis(SubchatCostCache)), do: start_supervised!(SubchatCostCache)
      :ok
    end

    test "idle retains a phase snapshot and explicit state reopening refreshes child costs", %{
      conn: conn
    } do
      %{user: actor, password: password} = user_fixture()
      conn = sign_in_conn(conn, actor.username, password)
      provider = create_provider!(actor)

      configuration =
        create_configuration!(actor, provider: provider, model_name: "bff-subchat-cost-model")

      root = create_chat!(actor, llm_configuration_id: configuration.id)
      source_message = persist_cost!(root, configuration, actor, 0.01)

      child =
        create_chat!(actor,
          llm_configuration_id: configuration.id,
          parent_chat_id: root.id,
          parent_message_id: source_message.id,
          parent_relation_kind: :fork,
          subagent: true
        )

      child_message = persist_cost!(child, configuration, actor, 0.02)

      next_step =
        ChatMessageStep
        |> Ash.Changeset.for_create(
          :create,
          %{chat_message_id: child_message.id, sequence: 2, status: :done},
          actor: actor
        )
        |> Ash.create!(actor: actor)

      initial_state =
        conn
        |> get(~p"/api/bff/chat-state/#{root.id}")
        |> json_response(200)

      initial_source = branch_message(initial_state, source_message.id)
      assert initial_source["usage"]["total_cost"] == 0.01
      assert initial_source["usage"]["subchat_cost"] == 0.02
      assert initial_source["usage"]["combined_total_cost"] == 0.03

      # Append only to the ledger: child lifecycle and parent phase stay unchanged.
      previous_usage =
        LlmUsageRecord
        |> Ash.Query.filter(chat_message_id == ^child_message.id)
        |> Ash.read_one!(actor: actor)

      attrs =
        previous_usage
        |> Map.take(Ash.Resource.Info.action(LlmUsageRecord, :create).accept)
        |> Map.delete(:external_id)
        |> Map.merge(%{
          chat_message_step_id: next_step.id,
          chat_message_step_id_snapshot: next_step.id,
          step_sequence: next_step.sequence,
          cost: 0.01
        })

      LlmUsageRecord
      |> Ash.Changeset.for_create(:create, attrs, actor: actor)
      |> Ash.create!(actor: actor)

      for _poll <- 1..3 do
        assert conn
               |> get(
                 ~p"/api/bff/chat-state/#{root.id}/idle-state?revision=#{initial_state["idle_revision"]}"
               )
               |> response(204) == ""
      end

      polled =
        conn
        |> get(~p"/api/bff/chat-messages/#{source_message.id}/poll")
        |> json_response(200)

      assert polled["usage"]["subchat_cost"] == 0.02

      changed_state =
        conn
        |> get(~p"/api/bff/chat-state/#{root.id}")
        |> json_response(200)

      changed_source = branch_message(changed_state, source_message.id)
      assert changed_source["usage"]["total_cost"] == 0.01
      assert changed_source["usage"]["subchat_cost"] == 0.03
      assert changed_source["usage"]["combined_total_cost"] == 0.04
      assert changed_state["idle_revision"] != initial_state["idle_revision"]

      assert conn
             |> get(
               ~p"/api/bff/chat-state/#{root.id}/idle-state?revision=#{changed_state["idle_revision"]}"
             )
             |> response(204) == ""
    end
  end

  defp create_fork_child!(%{actor: actor, parent: parent, parent_message: parent_message}) do
    create_chat!(actor,
      parent_chat_id: parent.id,
      parent_message_id: parent_message.id,
      parent_relation_kind: :fork,
      subagent: true
    )
  end

  defp idle_revision(conn, chat) do
    conn
    |> get(~p"/api/bff/chat-state/#{chat.id}/idle-state")
    |> json_response(200)
    |> Map.fetch!("revision")
  end

  # Asserts that the parent idle revision moved past `previous_revision`, that the
  # parent state exposes the child relation with the expected activity, and that
  # the state and idle endpoints agree on the revision. Returns the new revision.
  defp assert_child_activity(ctx, child, previous_revision, active_id, status) do
    %{conn: conn, parent: parent, parent_message: parent_message} = ctx

    idle =
      conn
      |> get(~p"/api/bff/chat-state/#{parent.id}/idle-state", revision: previous_revision)
      |> json_response(200)

    assert idle["revision"] != previous_revision

    state = conn |> get(~p"/api/bff/chat-state/#{parent.id}") |> json_response(200)

    relation =
      state["relations"]["children_by_message_id"]["#{parent_message.id}"]
      |> Enum.find(&(&1["chat_id"] == child.id))

    assert relation["active_generation_message_id"] == active_id
    assert relation["last_message_status"] == status
    assert state["idle_revision"] == idle["revision"]
    idle["revision"]
  end

  defp list_subchat(conn, parent, child) do
    conn
    |> get(~p"/api/bff/chat-list")
    |> json_response(200)
    |> Map.fetch!("chats")
    |> Enum.find(&(&1["id"] == parent.id))
    |> Map.fetch!("subchats")
    |> Enum.find(&(&1["id"] == child.id))
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
end
