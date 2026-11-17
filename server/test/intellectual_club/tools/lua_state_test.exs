defmodule IntellectualClub.Tools.LuaStateTest do
  use IntellectualClub.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias IntellectualClub.Accounts.UserGroupMembership
  alias IntellectualClub.Tools.{ExecutionContext, LuaState, ToolInstanceShare}

  require Ash.Query

  setup tags do
    %{user: actor} = user_fixture()
    tool = create_tool_instance!(actor, secrets: %{})
    root = create_empty_chat!(actor)
    context = execution_context(actor, root)

    if tags[:sandbox] == false do
      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Ash.destroy!(root, actor: actor)
          Ash.destroy!(tool, actor: actor)

          actor
          |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
          |> Ash.destroy!(authorize?: false)
        end)
      end)
    end

    %{actor: actor, tool: tool, root: root, context: context}
  end

  describe "state persistence" do
    test "starts with an empty object and commits the returned JSON and result", ctx do
      state = %{
        "count" => 1,
        "nested" => %{"values" => [nil, true, false, 1.25, "Привет", %{}, []]},
        "" => "untrimmed  "
      }

      assert {:ok, %{answer: 42}} =
               LuaState.with_state(ctx.tool, ctx.context, fn initial ->
                 assert initial == %{}
                 {:ok, %{answer: 42}, state}
               end)

      assert {:ok, :updated} =
               LuaState.with_state(ctx.tool, ctx.context, fn previous ->
                 assert previous == state
                 {:ok, :updated, Map.put(previous, "count", 2)}
               end)

      assert state_record!(ctx).state == Map.put(state, "count", 2)
    end

    test "the same actor and root share state across current subchats", ctx do
      child = create_subchat!(ctx.actor, ctx.root, :spawn)
      child_context = %{ctx.context | chat_id: child.id}

      assert {:ok, :saved} =
               LuaState.with_state(ctx.tool, ctx.context, fn _ ->
                 {:ok, :saved, %{"shared" => true}}
               end)

      assert {:ok, :child} =
               LuaState.with_state(ctx.tool, child_context, fn state ->
                 assert state == %{"shared" => true}
                 {:ok, :child, state}
               end)

      assert length(Ash.read!(LuaState, actor: ctx.actor)) == 1
    end

    test "different tools and roots have independent state", ctx do
      other_tool = create_tool_instance!(ctx.actor, secrets: %{})
      other_root = create_empty_chat!(ctx.actor)
      other_context = execution_context(ctx.actor, other_root)

      for {tool, context, marker} <- [
            {ctx.tool, ctx.context, "original"},
            {other_tool, ctx.context, "other tool"},
            {ctx.tool, other_context, "other root"}
          ] do
        assert {:ok, ^marker} =
                 LuaState.with_state(tool, context, fn state ->
                   assert state == %{}
                   {:ok, marker, %{"marker" => marker}}
                 end)
      end

      assert state_record!(ctx).state == %{"marker" => "original"}
      assert length(Ash.read!(LuaState, actor: ctx.actor)) == 3
    end

    test "shared tool users own separate state even in the same shared root", ctx do
      root =
        create_empty_chat!(ctx.actor,
          bot_id: create_bot!(ctx.actor).id,
          llm_configuration_id: create_configuration!(ctx.actor).id
        )

      ctx = %{ctx | root: root, context: execution_context(ctx.actor, root)}
      %{user: other} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [ctx.actor, other]})

      create!(
        ToolInstanceShare,
        %{tool_instance_id: ctx.tool.id, user_group_id: group.id},
        ctx.actor
      )

      share_chat!(ctx.actor, ctx.root, group)
      other_context = execution_context(other, ctx.root)

      for {context, value} <- [{ctx.context, "tool owner"}, {other_context, "executing user"}] do
        assert {:ok, ^value} =
                 LuaState.with_state(ctx.tool, context, fn state ->
                   assert state == %{}
                   {:ok, value, %{"value" => value}}
                 end)
      end

      [owned] = Ash.read!(LuaState, actor: ctx.actor)
      [other_owned] = Ash.read!(LuaState, actor: other)
      assert owned.owner_id == ctx.actor.id
      assert other_owned.owner_id == other.id
      assert owned.state == %{"value" => "tool owner"}
      assert other_owned.state == %{"value" => "executing user"}

      assert {:error, _} = Ash.get(LuaState, other_owned.id, actor: ctx.actor)

      assert {:error, _} =
               other_owned
               |> Ash.Changeset.for_update(:update, %{state: %{}}, actor: ctx.actor)
               |> Ash.update(actor: ctx.actor, authorize?: true)

      assert {:error, _} = Ash.destroy(other_owned, actor: ctx.actor, authorize?: true)
      assert Ash.get!(LuaState, other_owned.id, actor: other).state == other_owned.state
    end
  end

  describe "authorization" do
    test "requires a complete immutable execution context and never falls back to tool ownership",
         ctx do
      for context <- [
            nil,
            %{},
            Map.from_struct(ctx.context),
            %{ctx.context | owner_id: nil},
            %{ctx.context | chat_id: nil},
            %{ctx.context | root_chat_id: nil},
            %{ctx.context | owner_id: 0},
            %{ctx.context | root_chat_id: -1}
          ] do
        assert {:error, message} =
                 LuaState.with_state(ctx.tool, context, fn _ ->
                   flunk("unauthorized callback must not run")
                 end)

        assert message =~ "execution context"
      end

      assert Ash.read!(LuaState, actor: ctx.actor) == []
    end

    test "checks tool, current chat and root chat independently using the executing actor", ctx do
      %{user: other} = user_fixture()
      private_tool = create_tool_instance!(other, secrets: %{})
      private_chat = create_empty_chat!(other)

      for {tool, context} <- [
            {%{private_tool | owner_id: ctx.actor.id}, ctx.context},
            {ctx.tool, %{ctx.context | chat_id: private_chat.id}},
            {ctx.tool, %{ctx.context | root_chat_id: private_chat.id}},
            {ctx.tool, %{ctx.context | owner_id: other.id}}
          ] do
        assert {:error, message} =
                 LuaState.with_state(tool, context, fn _ ->
                   flunk("unauthorized callback must not run")
                 end)

        assert message =~ "not accessible"
      end

      assert Ash.read!(LuaState, actor: ctx.actor) == []
      assert Ash.read!(LuaState, actor: other) == []
    end

    test "cached tool access cannot survive revocation of sharing", ctx do
      %{user: other} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [ctx.actor, other]})

      share =
        create!(
          ToolInstanceShare,
          %{tool_instance_id: ctx.tool.id, user_group_id: group.id},
          ctx.actor
        )

      root = create_empty_chat!(other)
      context = execution_context(other, root)
      cached_tool = Ash.get!(IntellectualClub.Tools.ToolInstance, ctx.tool.id, actor: other)
      Ash.destroy!(share, actor: ctx.actor)

      assert {:error, message} =
               LuaState.with_state(cached_tool, context, fn _ ->
                 flunk("revoked callback must not run")
               end)

      assert message =~ "not accessible"
    end

    test "direct resource creation also requires related access and derives the owner", ctx do
      %{user: other} = user_fixture()

      assert {:error, _} =
               LuaState
               |> Ash.Changeset.for_create(
                 :create,
                 %{tool_instance_id: ctx.tool.id, root_chat_id: ctx.root.id},
                 actor: other
               )
               |> Ash.create(actor: other, authorize?: true)

      assert {:error, _} =
               LuaState
               |> Ash.Changeset.for_create(
                 :create,
                 %{tool_instance_id: ctx.tool.id, root_chat_id: ctx.root.id, owner_id: other.id},
                 actor: ctx.actor
               )
               |> Ash.create(actor: ctx.actor, authorize?: true)
    end
  end

  describe "rollback and JSON limits" do
    test "callback failures are safe, run once and create no row", ctx do
      parent = self()

      for callback <- [
            fn _ -> {:error, "private-value"} end,
            fn _ -> raise "private-value" end,
            fn _ -> throw({:private, "private-value"}) end,
            fn _ -> exit({:private, "private-value"}) end,
            fn _ -> {:unexpected, "private-value"} end,
            fn _ -> {:error, :timeout} end,
            fn _ -> exit({:timeout, "private-value"}) end
          ] do
        token = make_ref()

        assert {:error, message} =
                 LuaState.with_state(ctx.tool, ctx.context, fn state ->
                   send(parent, {:callback, token})
                   callback.(state)
                 end)

        assert_receive {:callback, ^token}
        refute_received {:callback, ^token}
        refute message =~ "private-value"
        assert state_record!(ctx) == nil
      end
    end

    test "a failed or timed out callback leaves an existing row entirely unchanged", ctx do
      assert {:ok, :saved} =
               LuaState.with_state(ctx.tool, ctx.context, fn _ ->
                 {:ok, :saved, %{"count" => 5}}
               end)

      original = state_record!(ctx)

      for reason <- [:timeout, "sensitive failure"] do
        assert {:error, _} =
                 LuaState.with_state(ctx.tool, ctx.context, fn state ->
                   assert state == original.state
                   {:error, reason}
                 end)

        current = state_record!(ctx)
        assert current.state == original.state
        assert current.updated_at == original.updated_at
      end
    end

    test "accepts exactly 256 KiB and rejects larger encoded JSON without changing state", ctx do
      boundary = %{"v" => String.duplicate("a", 256 * 1024 - 8)}
      assert byte_size(Jason.encode!(boundary)) == 256 * 1024

      assert {:ok, :saved} =
               LuaState.with_state(ctx.tool, ctx.context, fn _ -> {:ok, :saved, boundary} end)

      for too_large <- [
            %{"v" => boundary["v"] <> "a"},
            %{"v" => String.duplicate("\n", 128 * 1024)},
            %{"v" => String.duplicate("é", 128 * 1024)},
            %{"v" => List.duplicate(nil, 64 * 1024)}
          ] do
        assert {:error, message} =
                 LuaState.with_state(ctx.tool, ctx.context, fn _ -> {:ok, :ignored, too_large} end)

        assert message =~ "256 KiB"
        assert state_record!(ctx).state == boundary
      end
    end

    test "rejects excessive depth and non-JSON objects without creating state", ctx do
      too_deep = Enum.reduce(1..65, %{}, fn _, acc -> %{"child" => acc} end)

      assert {:error, message} =
               LuaState.with_state(ctx.tool, ctx.context, fn _ -> {:ok, nil, too_deep} end)

      assert message =~ "depth"

      for invalid <- [
            nil,
            [],
            "object",
            %{atom_key: 1},
            %{"value" => :atom},
            %{"value" => self()},
            %{"value" => {1, 2}},
            %{"value" => Date.utc_today()},
            %{"value" => <<255>>}
          ] do
        assert {:error, message} =
                 LuaState.with_state(ctx.tool, ctx.context, fn _ -> {:ok, nil, invalid} end)

        assert message =~ "JSON object"
        assert state_record!(ctx) == nil
      end

      boundary = Enum.reduce(1..64, %{}, fn _, acc -> %{"child" => acc} end)

      assert {:ok, :saved} =
               LuaState.with_state(ctx.tool, ctx.context, fn _ -> {:ok, :saved, boundary} end)
    end

    test "resource writes enforce the same limits outside with_state", ctx do
      too_large = %{"value" => String.duplicate("x", 256 * 1024)}

      assert {:error, _} =
               LuaState
               |> Ash.Changeset.for_create(
                 :create,
                 %{tool_instance_id: ctx.tool.id, root_chat_id: ctx.root.id, state: too_large},
                 actor: ctx.actor
               )
               |> Ash.create(actor: ctx.actor)

      assert {:ok, :saved} =
               LuaState.with_state(ctx.tool, ctx.context, fn _ -> {:ok, :saved, %{}} end)

      assert {:error, _} =
               state_record!(ctx)
               |> Ash.Changeset.for_update(:update, %{state: too_large}, actor: ctx.actor)
               |> Ash.update(actor: ctx.actor)

      assert state_record!(ctx).state == %{}
    end
  end

  describe "foreign key cleanup" do
    test "deleting the tool or root removes its stored state", ctx do
      other_root = create_empty_chat!(ctx.actor)
      other_context = execution_context(ctx.actor, other_root)

      for context <- [ctx.context, other_context] do
        assert {:ok, :saved} =
                 LuaState.with_state(ctx.tool, context, fn _ -> {:ok, :saved, %{}} end)
      end

      Ash.destroy!(other_root, actor: ctx.actor)
      assert length(Ash.read!(LuaState, actor: ctx.actor)) == 1

      Ash.destroy!(ctx.tool, actor: ctx.actor)
      assert Ash.read!(LuaState, actor: ctx.actor) == []
    end

    test "deleting the executing user removes state for a shared tool and root", ctx do
      root =
        create_empty_chat!(ctx.actor,
          bot_id: create_bot!(ctx.actor).id,
          llm_configuration_id: create_configuration!(ctx.actor).id
        )

      ctx = %{ctx | root: root, context: execution_context(ctx.actor, root)}
      %{user: other} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [ctx.actor, other]})

      create!(
        ToolInstanceShare,
        %{tool_instance_id: ctx.tool.id, user_group_id: group.id},
        ctx.actor
      )

      share_chat!(ctx.actor, ctx.root, group)
      context = execution_context(other, ctx.root)

      assert {:ok, :saved} =
               LuaState.with_state(ctx.tool, context, fn _ -> {:ok, :saved, %{}} end)

      # Remove unrelated group membership references before exercising the state FK.
      UserGroupMembership
      |> Ash.Query.filter(user_id == ^other.id)
      |> Ash.read!(authorize?: false)
      |> Enum.each(&Ash.destroy!(&1, authorize?: false))

      other
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
      |> Ash.destroy!(authorize?: false)

      assert Ash.read!(LuaState, actor: other) == []
    end
  end

  describe "independent database sessions" do
    @describetag sandbox: false

    setup do
      put_app_env(LuaState, lock_timeout_ms: 1_000, transaction_timeout_ms: 5_000)
      %{supervisor: start_supervised!(Task.Supervisor)}
    end

    test "same-key first writes serialize and each callback runs once", ctx do
      parent = self()

      first =
        state_task(ctx, fn state ->
          send(parent, {:entered, :first, self(), state})
          await_release()
          {:ok, :first, %{"count" => 1}}
        end)

      assert_receive {:entered, :first, first_pid, %{}}, 1_000

      second =
        state_task(ctx, fn state ->
          send(parent, {:entered, :second, self(), state})
          {:ok, :second, Map.update!(state, "count", &(&1 + 1))}
        end)

      second_pid = second.pid
      assert_receive {:calling, ^second_pid}, 1_000
      refute_receive {:entered, :second, _, _}, 50
      send(first_pid, :release)

      assert Task.await(first, 2_000) == {:ok, :first}
      assert Task.await(second, 2_000) == {:ok, :second}
      assert_receive {:entered, :second, ^second_pid, %{"count" => 1}}
      refute_received {:entered, :first, _, _}
      refute_received {:entered, :second, _, _}
      assert state_record!(ctx).state == %{"count" => 2}
      assert length(Ash.read!(LuaState, actor: ctx.actor)) == 1
    end

    test "different keys can enter and commit while another callback is blocked", ctx do
      other_root = create_empty_chat!(ctx.actor)
      other_context = execution_context(ctx.actor, other_root)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn -> Ash.destroy!(other_root, actor: ctx.actor) end)
      end)

      parent = self()

      first =
        state_task(ctx, fn state ->
          send(parent, {:blocked, self()})
          await_release()
          {:ok, :first, state}
        end)

      assert_receive {:blocked, first_pid}, 1_000

      second =
        state_task(%{ctx | context: other_context}, fn state ->
          {:ok, :independent, Map.put(state, "completed", true)}
        end)

      assert Task.await(second, 1_000) == {:ok, :independent}
      send(first_pid, :release)
      assert Task.await(first, 1_000) == {:ok, :first}
    end

    test "bounded lock contention does not call or replay the waiting callback", ctx do
      put_app_env(LuaState, lock_timeout_ms: 25, transaction_timeout_ms: 5_000)
      parent = self()

      first =
        state_task(ctx, fn state ->
          send(parent, {:blocked, self()})
          await_release()
          {:ok, :first, Map.put(state, "count", 1)}
        end)

      assert_receive {:blocked, first_pid}, 1_000

      waiter =
        state_task(ctx, fn state ->
          send(parent, :waiting_callback_ran)
          {:ok, :unexpected, state}
        end)

      assert {:error, message} = Task.await(waiter, 1_000)
      assert message =~ "timed out"
      refute_received :waiting_callback_ran
      send(first_pid, :release)
      assert Task.await(first, 1_000) == {:ok, :first}
      refute_received :waiting_callback_ran
      assert state_record!(ctx).state == %{"count" => 1}
    end

    @tag :capture_log
    test "terminating the transaction caller rolls back and releases its scope lock", ctx do
      parent = self()

      call =
        state_task(ctx, fn _state ->
          send(parent, :callback_blocked)
          await_release()
          {:ok, :unexpected, %{"should_not_persist" => true}}
        end)

      assert_receive :callback_blocked, 1_000
      assert Task.shutdown(call, :brutal_kill) == nil
      assert state_record!(ctx) == nil

      assert {:ok, :recovered} =
               LuaState.with_state(ctx.tool, ctx.context, fn state ->
                 assert state == %{}
                 {:ok, :recovered, %{"recovered" => true}}
               end)
    end
  end

  defp execution_context(actor, chat) do
    %ExecutionContext{owner_id: actor.id, chat_id: chat.id, root_chat_id: chat.id}
  end

  defp state_record!(ctx) do
    LuaState
    |> Ash.Query.filter(
      tool_instance_id == ^ctx.tool.id and owner_id == ^ctx.context.owner_id and
        root_chat_id == ^ctx.context.root_chat_id
    )
    |> Ash.read_one!(actor: ctx.actor, authorize?: true)
  end

  defp state_task(ctx, callback) do
    parent = self()

    Task.Supervisor.async_nolink(ctx.supervisor, fn ->
      Sandbox.unboxed_run(Repo, fn ->
        send(parent, {:calling, self()})
        LuaState.with_state(ctx.tool, ctx.context, callback)
      end)
    end)
  end

  defp await_release do
    receive do
      :release -> :ok
    after
      2_000 -> flunk("callback barrier was not released")
    end
  end
end
