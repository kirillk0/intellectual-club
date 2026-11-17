defmodule IntellectualClub.Tools.Drivers.LuaTest do
  use IntellectualClub.DataCase, async: false
  alias IntellectualClub.Tools.Drivers.Lua, as: Driver
  alias IntellectualClub.Tools.{ExecutionContext, LuaState, Registry, ToolInstance}

  setup do
    %{user: actor} = user_fixture()
    chat = create_empty_chat!(actor)
    tool = create_tool_instance!(actor, type: "lua", config: Driver.default_config())
    context = %ExecutionContext{owner_id: actor.id, chat_id: chat.id, root_chat_id: chat.id}
    %{actor: actor, chat: chat, tool: tool, context: context}
  end

  test "metadata is static and does not evaluate source" do
    tool = %ToolInstance{
      config: Map.put(Driver.default_config(), "source", "error('must not execute')")
    }

    assert Registry.driver_for_type!("lua") == Driver
    assert "lua" in Registry.list_types()

    assert [%{"name" => "increment", "schema" => %{"type" => "object"}}] =
             Driver.fixed_functions(tool)

    refute Driver.supports_discovery?()
    refute Driver.interruptible?()
  end

  test "counter state follows the tool and chat family, not individual calls", ctx do
    assert {:ok, {_text, %{"result" => first}}} =
             Driver.execute(ctx.tool, "increment", %{"amount" => 2}, ctx.context)

    assert first["count"] == 2
    child = create_subchat!(ctx.actor, ctx.chat, :spawn)
    context = %{ctx.context | chat_id: child.id}

    assert {:ok, {_text, %{"result" => second}}} =
             Driver.execute(ctx.tool, "increment", %{"amount" => 3}, context)

    assert second["count"] == 5
    other_chat = create_empty_chat!(ctx.actor)
    context = %{ctx.context | chat_id: other_chat.id, root_chat_id: other_chat.id}

    assert {:ok, {_text, %{"result" => independent}}} =
             Driver.execute(ctx.tool, "increment", %{"amount" => 7}, context)

    assert independent["count"] == 7
  end

  test "exports, schemas and actor context are enforced before evaluation", ctx do
    assert {:error, _} = Driver.execute(ctx.tool, "helper", %{}, ctx.context)

    assert {:error, _} =
             Driver.execute(ctx.tool, "increment", %{"amount" => "not a number"}, ctx.context)

    assert {:error, _} = Driver.execute(ctx.tool, "increment", %{}, nil)
    %{user: other} = user_fixture()

    assert {:error, _} =
             Driver.execute(ctx.tool, "increment", %{"amount" => 1}, %{
               ctx.context
               | owner_id: other.id
             })

    assert Ash.read!(LuaState, actor: ctx.actor) == []
  end

  test "failed scripts leave the previous JSON unchanged and report the Lua error", ctx do
    assert {:ok, _} = Driver.execute(ctx.tool, "increment", %{"amount" => 4}, ctx.context)

    config =
      Map.put(
        ctx.tool.config,
        "source",
        "return {increment=function(args,ctx) ctx.state.count=99; error('deliberate failure') end}"
      )

    tool = Ash.update!(ctx.tool, %{config: config}, actor: ctx.actor, action: :update)
    assert {:error, message} = Driver.execute(tool, "increment", %{"amount" => 1}, ctx.context)
    assert message =~ "deliberate failure"
    assert message =~ "not rolled back"
    assert [%{state: %{"count" => 4}}] = Ash.read!(LuaState, actor: ctx.actor)
  end

  test "a cached tool cannot execute superseded source or permissions", ctx do
    config =
      Map.put(
        ctx.tool.config,
        "source",
        "return {increment=function(args,ctx) return {current=true} end}"
      )

    Ash.update!(ctx.tool, %{config: config}, actor: ctx.actor, action: :update)

    assert {:ok, {_text, %{"result" => %{"current" => true}}}} =
             Driver.execute(ctx.tool, "increment", %{}, ctx.context)
  end

  test "invalid source is rejected on save without running valid top-level code", ctx do
    assert {:error, _} =
             Ash.update(ctx.tool, %{config: Map.put(ctx.tool.config, "source", "return {")},
               actor: ctx.actor,
               action: :update
             )

    assert {:ok, _} =
             Ash.update(
               ctx.tool,
               %{config: Map.put(ctx.tool.config, "source", "while true do end")},
               actor: ctx.actor,
               action: :update
             )
  end
end
