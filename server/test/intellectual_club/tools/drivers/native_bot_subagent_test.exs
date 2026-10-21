defmodule IntellectualClub.Tools.Drivers.NativeBotSubagentTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Tools.Drivers.NativeBotSubagent
  alias IntellectualClub.Tools.DriverMetadata
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  describe "function catalog" do
    test "exposes spawn enabled and spawn_background disabled by default" do
      %{user: actor} = user_fixture()
      tool_instance = create_bot_subagent_tool!(actor, create_bot!(actor))

      functions = NativeBotSubagent.fixed_functions(tool_instance)
      assert Enum.map(functions, & &1["name"]) == ["spawn", "spawn_background"]

      assert Enum.map(functions, &{&1["enabled"], &1["enabled_by_default"]}) == [
               {true, true},
               {false, false}
             ]

      for function <- functions do
        assert function["schema"]["required"] == ["brief", "prompt"]
        assert function["schema"]["additionalProperties"] == false
        assert function["schema"]["properties"]["prompt"]["type"] == "string"
        assert String.contains?(function["description"], "configured bot")
      end

      spawn = Enum.find(functions, &(&1["name"] == "spawn"))
      refute Map.get(spawn, "is_background_function", false)

      spawn_background = Enum.find(functions, &(&1["name"] == "spawn_background"))
      assert spawn_background["is_background_function"] == true
      assert String.contains?(spawn_background["description"], "background task id")

      metadata = DriverMetadata.for_type("native-bot-subagent")
      assert metadata["title"] == "Bot Subagent"
      assert metadata["functions_mode"] == "fixed"
      assert metadata["supports_handoff"] == false
      assert Enum.map(metadata["fixed_functions"], & &1["enabled"]) == [true, false]
    end

    test "config schema requires a bot and shares the subchat policy keys" do
      assert NativeBotSubagent.default_config() == %{
               "nested_subchats_limit" => 0,
               "allow_handoff_in_subchats" => false
             }

      schema = NativeBotSubagent.config_schema()
      assert schema["required"] == ["bot_id"]

      assert Map.keys(schema["properties"]) |> Enum.sort() ==
               ["allow_handoff_in_subchats", "bot_id", "nested_subchats_limit"]

      assert schema["properties"]["bot_id"]["title"] == "Bot"
      assert schema["properties"]["bot_id"]["x-ui"]["widget"] == "bot-select"
      assert schema["properties"]["nested_subchats_limit"]["title"] == "Nested subchats limit"

      assert schema["properties"]["allow_handoff_in_subchats"]["title"] ==
               "Allow handoff in subchats"
    end
  end

  describe "configuration" do
    test "requires a readable bot and normalizes the stored values" do
      %{user: actor} = user_fixture()
      %{user: stranger} = user_fixture()
      bot = create_bot!(actor)
      foreign_bot = create_bot!(stranger)

      assert "Bot is required." in config_error_messages(actor, %{})

      assert "Bot is not available." in config_error_messages(actor, %{"bot_id" => foreign_bot.id})

      assert "Bot is not available." in config_error_messages(actor, %{"bot_id" => 999_999_999})
      assert "Bot must be a positive integer." in config_error_messages(actor, %{"bot_id" => "x"})

      tool_instance =
        create_tool_instance!(actor,
          type: "native-bot-subagent",
          config: %{
            "bot_id" => to_string(bot.id),
            "nested_subchats_limit" => "2",
            "allow_handoff_in_subchats" => "true"
          }
        )

      assert tool_instance.config == %{
               "bot_id" => bot.id,
               "nested_subchats_limit" => 2,
               "allow_handoff_in_subchats" => true
             }

      assert NativeBotSubagent.spawn_target(tool_instance) == {:bot, bot.id}

      assert {:error, "Bot subagent tool has no bot configured."} =
               NativeBotSubagent.spawn_target(%ToolInstance{tool_instance | config: %{}})
    end

    test "accepts a bot shared with the owner" do
      %{user: owner} = user_fixture()
      %{user: actor} = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, actor]})
      bot = create_bot!(owner)
      share_bot!(owner, bot, group)

      tool_instance = create_bot_subagent_tool!(actor, bot)
      assert tool_instance.config["bot_id"] == bot.id
    end
  end

  describe "execution" do
    for name <- ["spawn", "spawn_background"] do
      test "#{name} requires string brief and prompt and rejects extra fields" do
        %{user: actor} = user_fixture()
        tool_instance = create_bot_subagent_tool!(actor, create_bot!(actor))
        context = %ExecutionContext{owner_id: actor.id}
        name = unquote(name)

        for {args, error} <- [
              {%{"prompt" => "Do work"}, "brief is required"},
              {%{"brief" => "Work"}, "prompt is required"},
              {%{"brief" => 42, "prompt" => "Do work"}, "brief must be a string"},
              {%{"brief" => "Work", "prompt" => "Do work", "extra" => true},
               "spawn arguments contain unsupported fields"}
            ] do
          assert {:error, ^error} = NativeBotSubagent.execute(tool_instance, name, args, context)
        end

        assert {:error, message} =
                 NativeBotSubagent.execute(
                   tool_instance,
                   name,
                   %{"brief" => "Work", "prompt" => "Do work"},
                   nil
                 )

        assert String.ends_with?(message, "requires generation execution context.")
      end
    end

    test "background spawn is disabled by default and rejects an exhausted nesting limit before queueing" do
      %{user: actor} = user_fixture()
      root = create_empty_chat!(actor)
      source = create_subchat!(actor, root, :spawn)
      tool_instance = create_bot_subagent_tool!(actor, create_bot!(actor))
      args = %{"brief" => "Research", "prompt" => "Check one thing."}
      context = %ExecutionContext{owner_id: actor.id, chat_id: source.id}

      disabled =
        Executor.execute_llm_tool(
          %{"bot_subagent" => tool_instance},
          "bot_subagent__spawn_background",
          args,
          context
        )

      assert disabled.text == "Tool function `spawn_background` is disabled."
      assert disabled.raw["code"] == "tool_function_disabled"

      create_tool_function!(actor, tool_instance,
        name: "spawn_background",
        parameters_schema: %{}
      )

      result =
        Executor.execute_llm_tool(
          %{"bot_subagent" => tool_instance},
          "bot_subagent__spawn_background",
          args,
          context
        )

      assert result.text ==
               "Nested subchat creation is unavailable for this subagent. " <>
                 "Continue working on the task yourself without creating another subchat."

      assert result.raw["isError"] == true

      assert [] =
               BackgroundTask
               |> Ash.Query.filter(owner_id == ^actor.id)
               |> Ash.read!(actor: actor)
    end

    test "spawn functions become unavailable inside subchats once the limit is exhausted" do
      %{user: actor} = user_fixture()
      root = create_empty_chat!(actor)
      child = create_subchat!(actor, root, :spawn)
      bot = create_bot!(actor)

      exhausted = create_bot_subagent_tool!(actor, bot, %{"nested_subchats_limit" => 0})
      assert NativeBotSubagent.unavailable_functions(exhausted, root, actor) == []

      unavailable = NativeBotSubagent.unavailable_functions(exhausted, child, actor)
      assert "spawn" in unavailable
      assert "spawn_background" in unavailable

      one_level = create_bot_subagent_tool!(actor, bot, %{"nested_subchats_limit" => 1})
      assert NativeBotSubagent.unavailable_functions(one_level, child, actor) == []
    end
  end

  defp create_bot_subagent_tool!(actor, bot, config \\ %{}) do
    create_tool_instance!(actor,
      type: "native-bot-subagent",
      alias: "bot_subagent_#{System.unique_integer([:positive])}",
      config: Map.merge(%{"bot_id" => bot.id}, config)
    )
  end

  defp config_error_messages(actor, config) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-bot-subagent",
        name: unique_name("Bot subagent"),
        alias: "bot_subagent_#{System.unique_integer([:positive])}",
        config: config
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
    |> case do
      {:error, %Ash.Error.Invalid{errors: errors}} -> Enum.map(errors, & &1.message)
      {:ok, _tool_instance} -> []
    end
  end
end
