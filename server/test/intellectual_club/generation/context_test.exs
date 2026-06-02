defmodule IntellectualClub.Generation.ContextTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.Context
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.KnowledgeBlockFile
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.BotUserToolBinding
  alias IntellectualClub.Tools.BindingResolver
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolFunction
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  test "builds system prompt from bot blocks and prepends it to chat history" do
    %{user: actor} = user_fixture()

    first_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "First block",
          version: "v1",
          content: "First content"
        },
        actor: actor
      )
      |> Ash.create!()

    second_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Second block",
          version: "v1",
          content: "Second content"
        },
        actor: actor
      )
      |> Ash.create!()

    {:ok, first_block_file} =
      Files.create_from_binary("first-context.txt", "text/plain", "first block file")

    KnowledgeBlockFile
    |> Ash.Changeset.for_create(
      :create,
      %{knowledge_block_id: first_block.id, file_id: first_block_file.id, sequence: 0},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    {:ok, disabled_block_file} =
      Files.create_from_binary("disabled-context.txt", "text/plain", "disabled block file")

    KnowledgeBlockFile
    |> Ash.Changeset.for_create(
      :create,
      %{
        knowledge_block_id: first_block.id,
        file_id: disabled_block_file.id,
        enabled: false,
        sequence: 1
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Context bot",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 10,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          knowledge_block_id: second_block.id,
          enabled: true,
          sequence: 20
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          knowledge_block_id: first_block.id,
          enabled: true,
          sequence: 10
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Chat with bot", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _} = Threads.add_message_to_end(chat, :user, "First question", actor: actor)
    {:ok, _} = Threads.add_message_to_end(chat, :user, "Second question", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.bot_id == bot.id
    assert context.history_mode == :agent
    assert context.system_prompt != ""
    assert Regex.match?(~r/# First block.*# Second block/s, context.system_prompt)
    assert String.contains?(context.system_prompt, "First content")

    assert String.contains?(
             context.system_prompt,
             "[Attached file file_id=#{first_block_file.external_id}"
           )

    refute String.contains?(context.system_prompt, disabled_block_file.external_id)
    assert String.contains?(context.system_prompt, "Second content")
    assert first_block_file.external_id in context.available_file_external_ids
    refute disabled_block_file.external_id in context.available_file_external_ids

    assert Enum.at(context.messages, 0) == %{
             "role" => "system",
             "content" => context.system_prompt
           }

    assert Enum.drop(context.messages, 1) == [
             %{"role" => "user", "content" => "First question"},
             %{"role" => "user", "content" => "Second question"}
           ]
  end

  test "keeps pure chat history when no bot is selected" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Chat without bot", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _} = Threads.add_message_to_end(chat, :user, "Only history", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.bot_id == nil
    assert context.system_prompt == ""
    assert context.messages == [%{"role" => "user", "content" => "Only history"}]
  end

  test "passes fix role alteration from llm configuration into initial provider request" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "OpenRouter role fix",
          type: :openrouter_chat_completion,
          base_url: "https://openrouter.ai/api/v1",
          api_key: "provider-key"
        },
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "openai/gpt-5-mini",
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          fix_role_alteration: true
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Role fix chat",
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _assistant} =
      Threads.add_message_to_end(chat, :assistant, "Synthetic first turn",
        actor: actor,
        llm_configuration_id: configuration.id
      )

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.fix_role_alteration == true

    assert context.request_payload["messages"] == [
             %{"role" => "user", "content" => ""},
             %{"role" => "assistant", "content" => "Synthetic first turn"},
             %{"role" => "user", "content" => ""}
           ]
  end

  test "includes fixed driver functions in tools payload without discovery" do
    %{user: actor} = user_fixture()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Tools bot",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 10,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!()

    tool_instance =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-brave-search",
          name: "Brave Search",
          alias: "web",
          config: %{},
          secrets: %{"token" => "token-value"}
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: tool_instance.id,
          sharing_mode: :shared,
          enabled: true,
          sequence: 10
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Fixed tools chat", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _} = Threads.add_message_to_end(chat, :user, "Search for Elixir", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert %{} = context.tool_instances_by_alias
    assert context.tool_instances_by_alias["web"].id == tool_instance.id
    assert context.tool_instances_by_alias["web"].secrets == %{"bearer_token" => "token-value"}

    assert Enum.any?(context.tools_payload, fn item ->
             get_in(item, ["function", "name"]) == "web__web_search"
           end)
  end

  test "appends synthetic tool context grouped by active tool instance" do
    %{user: actor} = user_fixture()
    bot = create_tool_context_bot!(actor, "Synthetic tool context bot")

    staging_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "ssh",
          name: "Staging SSH",
          description: "Staging server.\nUse for staging checks.\nLiteral {{tool_target}}.",
          alias: "staging_ssh",
          config: %{"host" => "staging.example.com", "username" => "deploy"},
          secrets: %{}
        },
        actor: actor
      )
      |> Ash.create!()

    prod_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-brave-search",
          name: "Production Search",
          description: "Search docs for production incidents only.",
          alias: "prod_web",
          config: %{},
          secrets: %{"token" => "prod-token"}
        },
        actor: actor
      )
      |> Ash.create!()

    _disabled_upload =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: staging_tool.id,
          name: "upload_file",
          description: "Disabled upload override",
          parameters_schema: %{"type" => "object"},
          enabled: false,
          discovered_at: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!()

    create_bot_tool_binding!(actor, bot, staging_tool, :shared, 10)
    create_bot_tool_binding!(actor, bot, prod_tool, :shared, 20)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Synthetic tool context chat", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _} = Threads.add_message_to_end(chat, :user, "Check staging", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)
    snapshot = Context.prompt_snapshot!(chat.id, actor: actor)

    assert String.contains?(context.system_prompt, "# Available tool instances")
    assert snapshot.system_prompt == context.system_prompt

    assert String.contains?(
             context.system_prompt,
             "# Available tool instances\nThe available tools are grouped by tool instance."
           )

    assert String.contains?(
             context.system_prompt,
             "Tool names have the form `<tool_alias>__<function_name>`."
           )

    assert String.contains?(context.system_prompt, "## Tool instance `staging_ssh`")
    assert String.contains?(context.system_prompt, "Display name: Staging SSH")
    assert String.contains?(context.system_prompt, "Type: SSH (ssh)")

    assert String.contains?(
             context.system_prompt,
             "Type description: Execute remote commands on an SSH host."
           )

    assert String.contains?(
             context.system_prompt,
             "Type description: Execute remote commands on an SSH host.\n\n### Available functions\n- `"
           )

    assert String.contains?(context.system_prompt, "`staging_ssh__run_command`")
    assert String.contains?(context.system_prompt, "### Instance description\nStaging server.")
    assert String.contains?(context.system_prompt, "Literal {{tool_target}}.")
    refute String.contains?(context.system_prompt, "staging_ssh__upload_file")
    assert String.contains?(context.system_prompt, "## Tool instance `prod_web`")
    assert String.contains?(context.system_prompt, "`prod_web__web_search`")

    assert Enum.any?(context.tools_payload, fn item ->
             get_in(item, ["function", "name"]) == "staging_ssh__run_command"
           end)

    refute Enum.any?(context.tools_payload, fn item ->
             get_in(item, ["function", "name"]) == "staging_ssh__upload_file"
           end)
  end

  test "provider requests include synthetic tool context in provider-specific system fields" do
    %{user: actor} = user_fixture()
    bot = create_tool_context_bot!(actor, "Provider synthetic context bot")
    tool = create_context_tool!(actor, "Provider Search", "provider_web")
    create_bot_tool_binding!(actor, bot, tool, :shared, 10)

    chat_completion_config = create_llm_configuration!(actor, :openrouter_chat_completion)

    chat_completion_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Chat Completions synthetic context",
          bot_id: bot.id,
          llm_configuration_id: chat_completion_config.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _} = Threads.add_message_to_end(chat_completion_chat, :user, "Search", actor: actor)

    chat_completion_context =
      Context.build!(chat_completion_chat.id, actor: actor, chunk_delay_ms: 0)

    [system_message | _] = chat_completion_context.request_payload["messages"]
    assert system_message["role"] == "system"
    assert String.contains?(system_message["content"], "# Available tool instances")
    assert String.contains?(system_message["content"], "`provider_web__web_search`")

    responses_config = create_llm_configuration!(actor, :responses)

    responses_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Responses synthetic context",
          bot_id: bot.id,
          llm_configuration_id: responses_config.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _} = Threads.add_message_to_end(responses_chat, :user, "Search", actor: actor)

    responses_context = Context.build!(responses_chat.id, actor: actor, chunk_delay_ms: 0)

    assert String.contains?(
             responses_context.request_payload["instructions"],
             "# Available tool instances"
           )

    assert String.contains?(
             responses_context.request_payload["instructions"],
             "`provider_web__web_search`"
           )
  end

  test "synthetic tool context includes outlet runner instance context when online" do
    Runtime.reset!()

    %{user: actor} = user_fixture()
    bot = create_tool_context_bot!(actor, "Outlet instance context bot")

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "outlet",
          name: "Shell Outlet",
          description: "Local shell runner.",
          alias: "shell",
          config: %{},
          secrets: %{"token" => "runner-token"}
        },
        actor: actor
      )
      |> Ash.create!()

    _function =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool.id,
          name: "run_command",
          description: "Run a shell command.",
          parameters_schema: %{"type" => "object"},
          enabled: true,
          discovered_at: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!()

    {:ok, %{status: "idle"}} =
      Runtime.poll(tool, %{
        "runner_id" => "shell-runner",
        "runner_session_id" => "shell-session",
        "capacity" => 0,
        "max_wait_seconds" => 0,
        "metadata" => %{
          "hostname" => "dev-host",
          "platform" => "macos",
          "sys_platform" => "darwin",
          "os_name" => "posix",
          "shell_kind" => "zsh",
          "shell_display" => "/bin/zsh -c"
        }
      })

    create_bot_tool_binding!(actor, bot, tool, :shared, 10)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Outlet context chat", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _} = Threads.add_message_to_end(chat, :user, "Run pwd", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert String.contains?(context.system_prompt, "## Tool instance `shell`")
    assert String.contains?(context.system_prompt, "`shell__run_command`")

    assert String.contains?(
             context.system_prompt,
             "### Instance context\nRunner hostname: dev-host"
           )

    assert String.contains?(context.system_prompt, "Runner platform: macos")
    assert String.contains?(context.system_prompt, "Runner shell: /bin/zsh -c (kind: zsh)")
  end

  test "omits disabled fixed driver functions from tools payload and restores them when re-enabled" do
    %{user: actor} = user_fixture()
    bot = create_tool_context_bot!(actor, "Fixed function override bot")
    tool_instance = create_context_tool!(actor, "Fixed Search", "web")
    create_bot_tool_binding!(actor, bot, tool_instance, :shared, 10)

    _ =
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool_instance.id,
          name: "web_search",
          description: "Persisted override",
          parameters_schema: %{"type" => "object"},
          enabled: false,
          discovered_at: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Fixed disabled tools chat", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _} = Threads.add_message_to_end(chat, :user, "Search for Elixir", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    refute Enum.any?(context.tools_payload, fn item ->
             get_in(item, ["function", "name"]) == "web__web_search"
           end)

    ToolFunction
    |> Ash.Query.filter(tool_instance_id == ^tool_instance.id and name == "web_search")
    |> Ash.read_one!(actor: actor)
    |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor)
    |> Ash.update!(actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert Enum.any?(context.tools_payload, fn item ->
             get_in(item, ["function", "name"]) == "web__web_search"
           end)
  end

  test "chat tool binding contributes its tool instance alias alongside bot tools" do
    %{user: actor} = user_fixture()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Override bot",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 10,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!()

    bot_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-brave-search",
          name: "Bot Search",
          alias: "bot_web",
          config: %{},
          secrets: %{"token" => "bot-token"}
        },
        actor: actor
      )
      |> Ash.create!()

    chat_tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "native-brave-search",
          name: "Chat Search",
          alias: "web",
          config: %{},
          secrets: %{"token" => "chat-token"}
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      BotToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          bot_id: bot.id,
          tool_instance_id: bot_tool.id,
          sharing_mode: :shared,
          enabled: true,
          sequence: 0
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Override chat", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _ =
      ChatToolBinding
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_id: chat.id,
          tool_instance_id: chat_tool.id,
          enabled: true,
          sequence: 0
        },
        actor: actor
      )
      |> Ash.create!()

    {:ok, _} = Threads.add_message_to_end(chat, :user, "Find docs", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.tool_instances_by_alias["web"].id == chat_tool.id
    assert context.tool_instances_by_alias["bot_web"].id == bot_tool.id

    assert Enum.any?(context.tools_payload, fn item ->
             get_in(item, ["function", "name"]) == "web__web_search"
           end)
  end

  test "chat tool binding shadows bot binding with the same alias" do
    %{user: actor} = user_fixture()
    bot = create_tool_context_bot!(actor, "Shadow bot")
    bot_tool = create_context_tool!(actor, "Bot Search", "web")
    chat_tool = create_context_tool!(actor, "Chat Search", "web")

    create_bot_tool_binding!(actor, bot, bot_tool, :shared, 10)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Chat shadow", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    create_chat_tool_binding!(actor, chat, chat_tool, 0)

    {:ok, _} = Threads.add_message_to_end(chat, :user, "Find docs", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.tool_instances_by_alias["web"].id == chat_tool.id
    resolution = BindingResolver.resolve_for_chat(chat, actor)

    assert Enum.map(resolution.effective_tool_bindings, &{&1.alias, &1.source}) == [
             {"web", :chat}
           ]
  end

  test "user bot tool binding shadows creator binding with the same alias" do
    %{user: actor} = user_fixture()
    bot = create_tool_context_bot!(actor, "User override bot")
    bot_tool = create_context_tool!(actor, "Bot Search", "web")
    user_tool = create_context_tool!(actor, "User Search", "web")

    create_bot_tool_binding!(actor, bot, bot_tool, :shared, 100)

    BotUserToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{bot_id: bot.id, tool_instance_id: user_tool.id, enabled: true, sequence: 1},
      actor: actor
    )
    |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "User shadow", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _} = Threads.add_message_to_end(chat, :user, "Find docs", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.tool_instances_by_alias["web"].id == user_tool.id
    resolution = BindingResolver.resolve_for_chat(chat, actor)

    assert Enum.map(resolution.effective_tool_bindings, &{&1.alias, &1.source}) == [
             {"web", :user}
           ]
  end

  test "higher sequence shadows lower sequence at the same source priority" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Sequence shadow", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    lower_tool = create_context_tool!(actor, "Lower Search", "web")
    higher_tool = create_context_tool!(actor, "Higher Search", "web")

    create_chat_tool_binding!(actor, chat, lower_tool, 10)
    create_chat_tool_binding!(actor, chat, higher_tool, 20)

    {:ok, _} = Threads.add_message_to_end(chat, :user, "Find docs", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.tool_instances_by_alias["web"].id == higher_tool.id
    resolution = BindingResolver.resolve_for_chat(chat, actor)

    assert Enum.map(resolution.effective_tool_bindings, &{&1.alias, &1.sequence}) == [
             {"web", 20}
           ]
  end

  test "binding resolver reports artifact tools for effective bot and chat tools" do
    %{user: actor} = user_fixture()
    bot = create_tool_context_bot!(actor, "Artifact bot")
    bot_tool = create_artifact_context_tool!(actor, "Bot Artifact Reader", "files")
    create_bot_tool_binding!(actor, bot, bot_tool, :shared, 10)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Bot artifact tools", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert BindingResolver.resolve_for_chat(chat, actor).artifact_tools_available == true

    chat_tool = create_artifact_context_tool!(actor, "Chat Artifact Reader", "chat_files")
    create_chat_tool_binding!(actor, chat, chat_tool, 0)

    assert BindingResolver.resolve_for_chat(chat, actor).artifact_tools_available == true
  end

  test "binding resolver ignores disabled, shadowed, and functionless artifact tools" do
    %{user: actor} = user_fixture()
    bot = create_tool_context_bot!(actor, "Shadowed artifact bot")
    artifact_tool = create_artifact_context_tool!(actor, "Shadowed Artifact Reader", "web")
    search_tool = create_context_tool!(actor, "Chat Search", "web")

    create_bot_tool_binding!(actor, bot, artifact_tool, :shared, 10)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Shadowed artifact tools", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    create_chat_tool_binding!(actor, chat, search_tool, 0)

    assert BindingResolver.resolve_for_chat(chat, actor).artifact_tools_available == false

    disabled_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Disabled artifact tools", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    disabled_tool = create_artifact_context_tool!(actor, "Disabled Artifact Reader", "files")

    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_id: disabled_chat.id,
        tool_instance_id: disabled_tool.id,
        enabled: false,
        sequence: 0
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    assert BindingResolver.resolve_for_chat(disabled_chat, actor).artifact_tools_available ==
             false

    functionless_chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Functionless artifact tools", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    functionless_tool =
      create_artifact_context_tool!(actor, "Functionless Artifact Reader", "files")

    disable_all_artifact_reader_functions!(actor, functionless_tool)
    create_chat_tool_binding!(actor, functionless_chat, functionless_tool, 0)

    assert BindingResolver.resolve_for_chat(functionless_chat, actor).artifact_tools_available ==
             false
  end

  test "binding resolver reports artifact tools from user overrides" do
    %{user: actor} = user_fixture()
    bot = create_tool_context_bot!(actor, "User artifact bot")
    placeholder_tool = create_context_tool!(actor, "Placeholder Search", "files")
    user_tool = create_artifact_context_tool!(actor, "User Artifact Reader", "files")

    create_bot_tool_binding!(actor, bot, placeholder_tool, :per_user, 10)

    BotUserToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{bot_id: bot.id, tool_instance_id: user_tool.id, enabled: true, sequence: 1},
      actor: actor
    )
    |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "User artifact override", bot_id: bot.id, note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert BindingResolver.resolve_for_chat(chat, actor).artifact_tools_available == true
  end

  test "builds context up to selected parent when parent_id is provided" do
    %{user: actor} = user_fixture()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{title: "Parent-target chat", note: "", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

    {:ok, assistant_a} =
      Threads.add_message(chat, :assistant, "A", actor: actor, parent_id: root.id)

    {:ok, _assistant_b} =
      Threads.add_message(chat, :assistant, "B", actor: actor, parent_id: root.id)

    context = Context.build!(chat.id, actor: actor, parent_id: root.id, chunk_delay_ms: 0)

    assert context.history == [%{role: :user, content: "Root"}]
    assert context.messages == [%{"role" => "user", "content" => "Root"}]

    generating_message = Ash.get!(ChatMessage, context.message_id, actor: actor)
    assert generating_message.parent_id == root.id
    assert generating_message.status == :generating

    chat = Ash.get!(Chat, chat.id, actor: actor)
    assert chat.last_message_id == generating_message.id
    assert assistant_a.id != generating_message.id
  end

  test "builds system prompt from bot, chat and config blocks with block variable priority" do
    %{user: actor} = user_fixture()

    bot_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Bot block",
          version: "v1",
          content: "Bot says x={{x}} y={{y}} z={{z}}",
          variables: %{"x" => "bot-block-x"}
        },
        actor: actor
      )
      |> Ash.create!()

    chat_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Chat block",
          version: "v1",
          content: "Chat says x={{x}} y={{y}}",
          variables: %{"y" => "chat-block-y"}
        },
        actor: actor
      )
      |> Ash.create!()

    config_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Config block",
          version: "v1",
          content: "Config says x={{x}} y={{y}} z={{z}}",
          variables: %{"z" => "config-block-z"}
        },
        actor: actor
      )
      |> Ash.create!()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Prompt bot",
          first_messages: [],
          variables: %{"x" => "bot-x", "y" => "bot-y", "z" => "bot-z"},
          max_tool_rounds: 10,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, knowledge_block_id: bot_block.id, enabled: true, sequence: 10},
        actor: actor
      )
      |> Ash.create!()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Demo", type: :demo, base_url: nil, api_key: nil},
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "demo",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 1024,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      LlmConfigurationKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: configuration.id,
          knowledge_block_id: config_block.id,
          enabled: true,
          sequence: 30
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Prompt chat",
          bot_id: bot.id,
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      chat
      |> Ash.Changeset.for_update(
        :update,
        %{variables: %{"x" => "chat-x", "y" => "chat-y"}},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    _ =
      ChatKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, knowledge_block_id: chat_block.id, enabled: true, sequence: 20},
        actor: actor
      )
      |> Ash.create!()

    {:ok, _} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert Regex.match?(
             ~r/# Bot block.*# Chat block.*# Config block/s,
             context.system_prompt
           )

    assert String.contains?(
             context.system_prompt,
             "Bot says x=bot-block-x y=chat-y z=bot-z"
           )

    assert String.contains?(
             context.system_prompt,
             "Chat says x=chat-x y=chat-block-y"
           )

    assert String.contains?(
             context.system_prompt,
             "Config says x=chat-x y=chat-y z=config-block-z"
           )

    assert Enum.at(context.messages, 0) == %{
             "role" => "system",
             "content" => context.system_prompt
           }

    assert Enum.at(context.messages, 1) == %{"role" => "user", "content" => "hello"}
  end

  test "appends user knowledge blocks after configuration blocks" do
    %{user: actor} = user_fixture()

    bot_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Bot block", version: "v1", content: "bot"},
        actor: actor
      )
      |> Ash.create!()

    chat_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Chat block", version: "v1", content: "chat"},
        actor: actor
      )
      |> Ash.create!()

    config_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Config block", version: "v1", content: "config"},
        actor: actor
      )
      |> Ash.create!()

    user_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "User block", version: "v1", content: "user"},
        actor: actor
      )
      |> Ash.create!()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Prompt bot",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 10,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, knowledge_block_id: bot_block.id, enabled: true, sequence: 10},
        actor: actor
      )
      |> Ash.create!()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Demo", type: :demo, base_url: nil, api_key: nil},
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "demo",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 1024,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      LlmConfigurationKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: configuration.id,
          knowledge_block_id: config_block.id,
          enabled: true,
          sequence: 30
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Prompt chat",
          bot_id: bot.id,
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _ =
      ChatKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, knowledge_block_id: chat_block.id, enabled: true, sequence: 20},
        actor: actor
      )
      |> Ash.create!()

    _ =
      UserKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: user_block.id, enabled: true, sequence: 40},
        actor: actor
      )
      |> Ash.create!()

    {:ok, _} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert Regex.match?(
             ~r/# Bot block.*# Chat block.*# Config block.*# User block/s,
             context.system_prompt
           )

    assert String.contains?(context.system_prompt, "user")
  end

  test "places top configuration blocks before bot blocks and bottom blocks after chat blocks" do
    %{user: actor} = user_fixture()

    top_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Config top", version: "v1", content: "config-top"},
        actor: actor
      )
      |> Ash.create!()

    bot_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Bot block", version: "v1", content: "bot"},
        actor: actor
      )
      |> Ash.create!()

    chat_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Chat block", version: "v1", content: "chat"},
        actor: actor
      )
      |> Ash.create!()

    bottom_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Config bottom", version: "v1", content: "config-bottom"},
        actor: actor
      )
      |> Ash.create!()

    user_block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "User block", version: "v1", content: "user"},
        actor: actor
      )
      |> Ash.create!()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Prompt bot",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 10,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, knowledge_block_id: bot_block.id, enabled: true, sequence: 10},
        actor: actor
      )
      |> Ash.create!()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Demo", type: :demo, base_url: nil, api_key: nil},
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "demo",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 1024,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      LlmConfigurationKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: configuration.id,
          knowledge_block_id: top_block.id,
          selection: :top,
          enabled: true,
          sequence: 5
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      LlmConfigurationKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: configuration.id,
          knowledge_block_id: bottom_block.id,
          selection: :bottom,
          enabled: true,
          sequence: 30
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Prompt chat",
          bot_id: bot.id,
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _ =
      ChatKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{chat_id: chat.id, knowledge_block_id: chat_block.id, enabled: true, sequence: 20},
        actor: actor
      )
      |> Ash.create!()

    _ =
      UserKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{knowledge_block_id: user_block.id, enabled: true, sequence: 40},
        actor: actor
      )
      |> Ash.create!()

    {:ok, _} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)
    snapshot = Context.prompt_snapshot!(chat.id, actor: actor)

    assert Regex.match?(
             ~r/# Config top.*# Bot block.*# Chat block.*# Config bottom.*# User block/s,
             context.system_prompt
           )

    assert snapshot.system_prompt == context.system_prompt

    assert Enum.map(snapshot.prompt_blocks, & &1.knowledge_block.name) == [
             "Config top",
             "Bot block",
             "Chat block",
             "Config bottom",
             "User block"
           ]

    assert Enum.map(snapshot.prompt_blocks, & &1.source) == [
             :config,
             :bot,
             :chat,
             :config,
             :user
           ]

    assert Enum.map(snapshot.prompt_blocks, & &1.prompt_order) == [0, 1, 2, 3, 4]
  end

  test "builds chat provider history from answer and tool items while excluding reasoning" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "OpenRouter",
          type: :openrouter_chat_completion,
          base_url: "https://openrouter.ai/api/v1",
          api_key: "k"
        },
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "openai/gpt-5-nano",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 8192,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "History reconstruction chat",
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_1} = Threads.add_message_to_end(chat, :user, "What's the weather?", actor: actor)

    {:ok, assistant} =
      Threads.add_message_to_end(chat, :assistant, "",
        actor: actor,
        llm_configuration_id: configuration.id
      )

    step = create_step!(assistant.id, 2, actor)

    _ =
      create_item_with_text_and_opaque!(
        step.id,
        1,
        :tool_call,
        "Tool call: weather__get",
        %{
          "tool_call_id" => "call_weather",
          "name" => "weather__get",
          "arguments" => %{"city" => "Paris"},
          "raw" => %{
            "id" => "call_weather",
            "type" => "function",
            "function" => %{"name" => "weather__get", "arguments" => ~s({"city":"Paris"})}
          }
        },
        actor
      )

    _ = create_item_with_text!(step.id, 2, :reasoning, "Hidden reasoning text", actor)

    _ =
      create_item_with_text_and_opaque!(
        step.id,
        3,
        :tool_result,
        ~s({"temperature":18.5}),
        %{
          "tool_call_id" => "call_weather",
          "name" => "weather__get",
          "raw" => %{"temperature" => 18.5}
        },
        actor
      )

    _ = create_item_with_text!(step.id, 4, :answer, "It is 18.5°C in Paris.", actor)

    {:ok, _user_2} = Threads.add_message_to_end(chat, :user, "And tomorrow?", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.provider_type == "openrouter_chat_completion"

    assert context.messages == [
             %{"role" => "user", "content" => "What's the weather?"},
             %{
               "role" => "assistant",
               "content" => "It is 18.5°C in Paris.",
               "tool_calls" => [
                 %{
                   "id" => "call_weather",
                   "type" => "function",
                   "function" => %{"name" => "weather__get", "arguments" => ~s({"city":"Paris"})}
                 }
               ]
             },
             %{
               "role" => "tool",
               "tool_call_id" => "call_weather",
               "content" => ~s({"temperature":18.5})
             },
             %{"role" => "user", "content" => "And tomorrow?"}
           ]

    assistant_history = Enum.at(context.messages, 1)
    refute Map.has_key?(assistant_history, "reasoning")
    refute Map.has_key?(assistant_history, "reasoning_details")
  end

  test "uses missing provider adapter for provider types unavailable in the application build" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Legacy provider", type: :demo, auth_method: :api_key},
        actor: actor
      )
      |> Ash.create!()

    Ecto.Adapters.SQL.query!(
      Db.repo(),
      "UPDATE llm_providers SET type = ? WHERE id = ?",
      ["missing_provider_type", provider.id]
    )

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "legacy-model",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 8192,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Legacy provider chat",
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_message} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.provider_type == "missing_provider_type"
    assert context.adapter_module == IntellectualClub.Llm.Providers.Common.MissingProvider

    assert :ok =
             context.adapter_module.stream_generate(
               %{context: context, request_payload: context.request_payload},
               fn event -> send(self(), event) end
             )

    assert_receive {:response_error,
                    %{
                      provider: "missing_provider_type",
                      error_kind: "configuration",
                      error_text: "Provider type is not available: missing_provider_type"
                    }}
  end

  test "keeps completed prefix of canceled assistant messages in chat provider history" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "OpenRouter",
          type: :openrouter_chat_completion,
          base_url: "https://openrouter.ai/api/v1",
          api_key: "k"
        },
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "openai/gpt-5-nano",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 8192,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Canceled chat history reconstruction",
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_1} = Threads.add_message_to_end(chat, :user, "What's the weather?", actor: actor)

    assistant =
      create_assistant_message!(chat, user_1, actor,
        llm_configuration_id: configuration.id,
        status: :canceled
      )

    completed_step = create_step!(assistant.id, 1, actor, %{status: :done})

    _ =
      create_item_with_text_and_opaque!(
        completed_step.id,
        1,
        :tool_call,
        "Tool call: weather__get",
        %{
          "tool_call_id" => "call_weather",
          "name" => "weather__get",
          "arguments" => %{"city" => "Paris"},
          "raw" => %{
            "id" => "call_weather",
            "type" => "function",
            "function" => %{"name" => "weather__get", "arguments" => ~s({"city":"Paris"})}
          }
        },
        actor
      )

    _ =
      create_item_with_text_and_opaque!(
        completed_step.id,
        2,
        :tool_result,
        ~s({"temperature":18.5}),
        %{
          "tool_call_id" => "call_weather",
          "name" => "weather__get",
          "raw" => %{"temperature" => 18.5}
        },
        actor
      )

    _ = create_item_with_text!(completed_step.id, 3, :answer, "It is 18.5°C in Paris.", actor)

    canceled_step = create_step!(assistant.id, 2, actor, %{status: :canceled})
    _ = create_item_with_text!(canceled_step.id, 1, :answer, "Checking tomorrow.", actor)

    _ =
      create_item_with_text_and_opaque!(
        canceled_step.id,
        2,
        :tool_call,
        "Tool call: weather__get",
        %{
          "tool_call_id" => "call_tomorrow",
          "name" => "weather__get",
          "arguments" => %{"city" => "Paris", "day" => "tomorrow"},
          "raw" => %{
            "id" => "call_tomorrow",
            "type" => "function",
            "function" => %{
              "name" => "weather__get",
              "arguments" => ~s({"city":"Paris","day":"tomorrow"})
            }
          }
        },
        actor
      )

    {:ok, _user_2} = Threads.add_message_to_end(chat, :user, "And tomorrow?", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.messages == [
             %{"role" => "user", "content" => "What's the weather?"},
             %{
               "role" => "assistant",
               "content" => "It is 18.5°C in Paris.",
               "tool_calls" => [
                 %{
                   "id" => "call_weather",
                   "type" => "function",
                   "function" => %{"name" => "weather__get", "arguments" => ~s({"city":"Paris"})}
                 }
               ]
             },
             %{
               "role" => "tool",
               "tool_call_id" => "call_weather",
               "content" => ~s({"temperature":18.5})
             },
             %{"role" => "user", "content" => canceled_turn_aborted_marker()},
             %{"role" => "user", "content" => "And tomorrow?"}
           ]

    refute Enum.any?(context.messages, fn message ->
             message["role"] == "assistant" and
               String.contains?(message["content"] || "", "Checking tomorrow.")
           end)
  end

  test "keeps completed prefix of errored assistant messages in chat provider history" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "OpenRouter",
          type: :openrouter_chat_completion,
          base_url: "https://openrouter.ai/api/v1",
          api_key: "k"
        },
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "openai/gpt-5-nano",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 8192,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Errored chat history reconstruction",
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_1} = Threads.add_message_to_end(chat, :user, "What's the weather?", actor: actor)

    assistant =
      create_assistant_message!(chat, user_1, actor,
        llm_configuration_id: configuration.id,
        status: :error,
        error_detail: "Provider timeout"
      )

    completed_step = create_step!(assistant.id, 1, actor, %{status: :done})

    _ =
      create_item_with_text_and_opaque!(
        completed_step.id,
        1,
        :tool_call,
        "Tool call: weather__get",
        %{
          "tool_call_id" => "call_weather",
          "name" => "weather__get",
          "arguments" => %{"city" => "Paris"},
          "raw" => %{
            "id" => "call_weather",
            "type" => "function",
            "function" => %{"name" => "weather__get", "arguments" => ~s({"city":"Paris"})}
          }
        },
        actor
      )

    _ =
      create_item_with_text_and_opaque!(
        completed_step.id,
        2,
        :tool_result,
        ~s({"temperature":18.5}),
        %{
          "tool_call_id" => "call_weather",
          "name" => "weather__get",
          "raw" => %{"temperature" => 18.5}
        },
        actor
      )

    _ = create_item_with_text!(completed_step.id, 3, :answer, "It is 18.5°C in Paris.", actor)

    error_step = create_step!(assistant.id, 2, actor, %{status: :error})
    _ = create_item_with_text!(error_step.id, 1, :answer, "Checking tomorrow.", actor)

    _ =
      create_item_with_text_and_opaque!(
        error_step.id,
        2,
        :tool_call,
        "Tool call: weather__get",
        %{
          "tool_call_id" => "call_tomorrow",
          "name" => "weather__get",
          "arguments" => %{"city" => "Paris", "day" => "tomorrow"},
          "raw" => %{
            "id" => "call_tomorrow",
            "type" => "function",
            "function" => %{
              "name" => "weather__get",
              "arguments" => ~s({"city":"Paris","day":"tomorrow"})
            }
          }
        },
        actor
      )

    {:ok, _user_2} = Threads.add_message_to_end(chat, :user, "And tomorrow?", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.messages == [
             %{"role" => "user", "content" => "What's the weather?"},
             %{
               "role" => "assistant",
               "content" => "It is 18.5°C in Paris.",
               "tool_calls" => [
                 %{
                   "id" => "call_weather",
                   "type" => "function",
                   "function" => %{"name" => "weather__get", "arguments" => ~s({"city":"Paris"})}
                 }
               ]
             },
             %{
               "role" => "tool",
               "tool_call_id" => "call_weather",
               "content" => ~s({"temperature":18.5})
             },
             %{"role" => "user", "content" => error_turn_aborted_marker("Provider timeout")},
             %{"role" => "user", "content" => "And tomorrow?"}
           ]

    refute Enum.any?(context.messages, fn message ->
             message["role"] == "assistant" and
               String.contains?(message["content"] || "", "Checking tomorrow.")
           end)
  end

  test "includes placeholder tool result when tool output is empty" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "OpenRouter",
          type: :openrouter_chat_completion,
          base_url: "https://openrouter.ai/api/v1",
          api_key: "k"
        },
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "anthropic/claude-opus-4.6",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 8192,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Empty tool output chat",
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_1} = Threads.add_message_to_end(chat, :user, "Run tool", actor: actor)

    {:ok, assistant} =
      Threads.add_message_to_end(chat, :assistant, "",
        actor: actor,
        llm_configuration_id: configuration.id
      )

    step = create_step!(assistant.id, 2, actor)

    _ =
      create_item_with_text_and_opaque!(
        step.id,
        1,
        :tool_call,
        "Tool call: weather__get",
        %{
          "tool_call_id" => "call_empty_output",
          "name" => "weather__get",
          "arguments" => %{"city" => "Paris"},
          "raw" => %{
            "id" => "call_empty_output",
            "type" => "function",
            "function" => %{"name" => "weather__get", "arguments" => ~s({"city":"Paris"})}
          }
        },
        actor
      )

    _ =
      create_item_with_text_and_opaque!(
        step.id,
        2,
        :tool_result,
        "",
        %{
          "tool_call_id" => "call_empty_output",
          "name" => "weather__get",
          "raw" => %{}
        },
        actor
      )

    {:ok, _user_2} = Threads.add_message_to_end(chat, :user, "Next", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.provider_type == "openrouter_chat_completion"

    assert context.messages == [
             %{"role" => "user", "content" => "Run tool"},
             %{
               "role" => "assistant",
               "content" => "",
               "tool_calls" => [
                 %{
                   "id" => "call_empty_output",
                   "type" => "function",
                   "function" => %{"name" => "weather__get", "arguments" => ~s({"city":"Paris"})}
                 }
               ]
             },
             %{
               "role" => "tool",
               "tool_call_id" => "call_empty_output",
               "content" => "(tool returned no output)"
             },
             %{"role" => "user", "content" => "Next"}
           ]
  end

  test "builds responses history from answer and tool items while excluding reasoning" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Responses",
          type: :responses,
          base_url: "https://api.openai.com/v1",
          api_key: "k"
        },
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "gpt-5-nano",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 8192,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Responses history reconstruction chat",
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_1} = Threads.add_message_to_end(chat, :user, "What's the weather?", actor: actor)

    {:ok, assistant} =
      Threads.add_message_to_end(chat, :assistant, "",
        actor: actor,
        llm_configuration_id: configuration.id
      )

    step = create_step!(assistant.id, 2, actor)

    _ =
      create_item_with_text_and_opaque!(
        step.id,
        1,
        :tool_call,
        "Tool call: weather__get",
        %{
          "type" => "function_call",
          "id" => "fc_call_weather",
          "call_id" => "call_weather",
          "name" => "weather__get",
          "arguments" => ~s({"city":"Paris"})
        },
        actor
      )

    _ =
      create_item_with_text_and_opaque!(
        step.id,
        2,
        :reasoning,
        "Hidden reasoning text",
        %{
          "type" => "reasoning",
          "id" => "rs_123",
          "summary" => [%{"type" => "summary_text", "text" => "hidden"}]
        },
        actor
      )

    _ =
      create_item_with_text_and_opaque!(
        step.id,
        3,
        :tool_result,
        ~s({"temperature":18.5}),
        %{
          "type" => "function_call_output",
          "id" => "fco_call_weather",
          "call_id" => "call_weather",
          "output" => ~s({"temperature":18.5})
        },
        actor
      )

    _ = create_item_with_text!(step.id, 4, :answer, "It is 18.5°C in Paris.", actor)

    {:ok, _user_2} = Threads.add_message_to_end(chat, :user, "And tomorrow?", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.provider_type == "responses"
    assert is_list(context.messages)
    assert Enum.all?(context.messages, &is_map/1)
    refute Enum.any?(context.messages, &(Map.get(&1, "type") == "reasoning"))

    assert context.messages == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "What's the weather?"}]
             },
             %{
               "type" => "function_call",
               "id" => "fc_call_weather",
               "call_id" => "call_weather",
               "name" => "weather__get",
               "arguments" => ~s({"city":"Paris"})
             },
             %{
               "type" => "function_call_output",
               "id" => "fco_call_weather",
               "call_id" => "call_weather",
               "output" => ~s({"temperature":18.5})
             },
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "final_answer",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "It is 18.5°C in Paris.",
                   "annotations" => []
                 }
               ]
             },
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "And tomorrow?"}]
             }
           ]

    assert Map.get(context.request_payload, "input") == context.messages
    assert Map.get(context.request_payload, "store") == false
  end

  test "keeps completed prefix of canceled assistant messages in responses history" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Responses",
          type: :responses,
          base_url: "https://api.openai.com/v1",
          api_key: "k"
        },
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "gpt-5-nano",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 8192,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Canceled responses history reconstruction",
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_1} = Threads.add_message_to_end(chat, :user, "What's the weather?", actor: actor)

    assistant =
      create_assistant_message!(chat, user_1, actor,
        llm_configuration_id: configuration.id,
        status: :canceled
      )

    completed_step = create_step!(assistant.id, 1, actor, %{status: :done})

    _ =
      create_item_with_text_and_opaque!(
        completed_step.id,
        1,
        :tool_call,
        "Tool call: weather__get",
        %{
          "type" => "function_call",
          "id" => "fc_call_weather",
          "call_id" => "call_weather",
          "name" => "weather__get",
          "arguments" => ~s({"city":"Paris"})
        },
        actor
      )

    _ =
      create_item_with_text_and_opaque!(
        completed_step.id,
        2,
        :tool_result,
        ~s({"temperature":18.5}),
        %{
          "type" => "function_call_output",
          "id" => "fco_call_weather",
          "call_id" => "call_weather",
          "output" => ~s({"temperature":18.5})
        },
        actor
      )

    _ = create_item_with_text!(completed_step.id, 3, :answer, "It is 18.5°C in Paris.", actor)

    canceled_step = create_step!(assistant.id, 2, actor, %{status: :canceled})
    _ = create_item_with_text!(canceled_step.id, 1, :answer, "Checking tomorrow.", actor)

    _ =
      create_item_with_text_and_opaque!(
        canceled_step.id,
        2,
        :tool_call,
        "Tool call: weather__get",
        %{
          "type" => "function_call",
          "id" => "fc_call_tomorrow",
          "call_id" => "call_tomorrow",
          "name" => "weather__get",
          "arguments" => ~s({"city":"Paris","day":"tomorrow"})
        },
        actor
      )

    {:ok, _user_2} = Threads.add_message_to_end(chat, :user, "And tomorrow?", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.messages == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "What's the weather?"}]
             },
             %{
               "type" => "function_call",
               "id" => "fc_call_weather",
               "call_id" => "call_weather",
               "name" => "weather__get",
               "arguments" => ~s({"city":"Paris"})
             },
             %{
               "type" => "function_call_output",
               "id" => "fco_call_weather",
               "call_id" => "call_weather",
               "output" => ~s({"temperature":18.5})
             },
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "final_answer",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "It is 18.5°C in Paris.",
                   "annotations" => []
                 }
               ]
             },
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => canceled_turn_aborted_marker()}]
             },
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "And tomorrow?"}]
             }
           ]

    refute Enum.any?(context.messages, fn item ->
             item["type"] == "function_call" and item["call_id"] == "call_tomorrow"
           end)
  end

  test "keeps completed prefix of errored assistant messages in responses history" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Responses",
          type: :responses,
          base_url: "https://api.openai.com/v1",
          api_key: "k"
        },
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "gpt-5-nano",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 8192,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Errored responses history reconstruction",
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_1} = Threads.add_message_to_end(chat, :user, "What's the weather?", actor: actor)

    assistant =
      create_assistant_message!(chat, user_1, actor,
        llm_configuration_id: configuration.id,
        status: :error,
        error_detail: "Provider timeout"
      )

    completed_step = create_step!(assistant.id, 1, actor, %{status: :done})

    _ =
      create_item_with_text_and_opaque!(
        completed_step.id,
        1,
        :tool_call,
        "Tool call: weather__get",
        %{
          "type" => "function_call",
          "id" => "fc_call_weather",
          "call_id" => "call_weather",
          "name" => "weather__get",
          "arguments" => ~s({"city":"Paris"})
        },
        actor
      )

    _ =
      create_item_with_text_and_opaque!(
        completed_step.id,
        2,
        :tool_result,
        ~s({"temperature":18.5}),
        %{
          "type" => "function_call_output",
          "id" => "fco_call_weather",
          "call_id" => "call_weather",
          "output" => ~s({"temperature":18.5})
        },
        actor
      )

    _ = create_item_with_text!(completed_step.id, 3, :answer, "It is 18.5°C in Paris.", actor)

    error_step = create_step!(assistant.id, 2, actor, %{status: :error})
    _ = create_item_with_text!(error_step.id, 1, :answer, "Checking tomorrow.", actor)

    _ =
      create_item_with_text_and_opaque!(
        error_step.id,
        2,
        :tool_call,
        "Tool call: weather__get",
        %{
          "type" => "function_call",
          "id" => "fc_call_tomorrow",
          "call_id" => "call_tomorrow",
          "name" => "weather__get",
          "arguments" => ~s({"city":"Paris","day":"tomorrow"})
        },
        actor
      )

    {:ok, _user_2} = Threads.add_message_to_end(chat, :user, "And tomorrow?", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.messages == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "What's the weather?"}]
             },
             %{
               "type" => "function_call",
               "id" => "fc_call_weather",
               "call_id" => "call_weather",
               "name" => "weather__get",
               "arguments" => ~s({"city":"Paris"})
             },
             %{
               "type" => "function_call_output",
               "id" => "fco_call_weather",
               "call_id" => "call_weather",
               "output" => ~s({"temperature":18.5})
             },
             %{
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "phase" => "final_answer",
               "content" => [
                 %{
                   "type" => "output_text",
                   "text" => "It is 18.5°C in Paris.",
                   "annotations" => []
                 }
               ]
             },
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{
                   "type" => "input_text",
                   "text" => error_turn_aborted_marker("Provider timeout")
                 }
               ]
             },
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "And tomorrow?"}]
             }
           ]

    refute Enum.any?(context.messages, fn item ->
             item["type"] == "function_call" and item["call_id"] == "call_tomorrow"
           end)
  end

  test "applies cache control markers for supported chat configurations" do
    %{user: actor} = user_fixture()

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Prompt", version: "v1", content: "System guidance"},
        actor: actor
      )
      |> Ash.create!()

    bot =
      Bot
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Cache bot",
          first_messages: [],
          variables: %{},
          max_tool_rounds: 10,
          context_soft_limit_percent: 80,
          history_mode: :chat
        },
        actor: actor
      )
      |> Ash.create!()

    _ =
      BotKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{bot_id: bot.id, knowledge_block_id: block.id, enabled: true, sequence: 10},
        actor: actor
      )
      |> Ash.create!()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "OpenRouter",
          type: :openrouter_chat_completion,
          base_url: "https://openrouter.ai/api/v1",
          api_key: "k"
        },
        actor: actor
      )
      |> Ash.create!()

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "anthropic/claude-sonnet-4",
          note: nil,
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 8192,
          supports_cache_control: true,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!()

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Cache control chat",
          bot_id: bot.id,
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

    context = Context.build!(chat.id, actor: actor, chunk_delay_ms: 0)

    assert context.cache_control_enabled == true
    assert context.history_length == 2

    system_message = Enum.at(context.messages, 0)
    user_message = Enum.at(context.messages, 1)

    assert system_message["role"] == "system"
    assert is_list(system_message["content"])
    assert List.last(system_message["content"])["cache_control"] == %{"type" => "ephemeral"}

    assert user_message["role"] == "user"
    assert is_list(user_message["content"])
    assert List.last(user_message["content"])["cache_control"] == %{"type" => "ephemeral"}

    payload_messages = Map.get(context.request_payload, "messages")
    assert payload_messages == context.messages
  end

  defp create_tool_context_bot!(actor, name) do
    Bot
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        first_messages: [],
        variables: %{},
        max_tool_rounds: 10,
        context_soft_limit_percent: 80,
        history_mode: :chat
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_context_tool!(actor, name, alias_value) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-brave-search",
        name: name,
        alias: alias_value,
        config: %{},
        secrets: %{"token" => "#{name}-token"}
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_artifact_context_tool!(actor, name, alias_value) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{
        type: "native-artifact-reader",
        name: name,
        alias: alias_value,
        config: %{},
        secrets: %{}
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp disable_all_artifact_reader_functions!(actor, tool) do
    ["read_file", "search_file", "read_image", "upload_file"]
    |> Enum.each(fn name ->
      ToolFunction
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool.id,
          name: name,
          description: "",
          parameters_schema: %{},
          enabled: false,
          discovered_at: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)
    end)
  end

  defp create_bot_tool_binding!(actor, bot, tool, sharing_mode, sequence) do
    BotToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{
        bot_id: bot.id,
        tool_instance_id: tool.id,
        sharing_mode: sharing_mode,
        enabled: true,
        sequence: sequence
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_chat_tool_binding!(actor, chat, tool, sequence) do
    ChatToolBinding
    |> Ash.Changeset.for_create(
      :create,
      %{chat_id: chat.id, tool_instance_id: tool.id, enabled: true, sequence: sequence},
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_llm_configuration!(actor, provider_type) do
    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "#{provider_type} provider",
          type: provider_type,
          base_url: provider_base_url(provider_type),
          api_key: "provider-key"
        },
        actor: actor
      )
      |> Ash.create!()

    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: "test-model",
        note: nil,
        parameters: %{},
        enabled: true,
        timeout_seconds: 30,
        context_length: 8192,
        supports_cache_control: false,
        supports_image_input: false
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp provider_base_url(:responses), do: "https://api.openai.com/v1"
  defp provider_base_url(:openrouter_chat_completion), do: "https://openrouter.ai/api/v1"
  defp provider_base_url(_type), do: "https://example.com/v1"

  defp create_step!(message_id, sequence, actor, attrs \\ %{}) do
    ChatMessageStep
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{chat_message_id: message_id, sequence: sequence}, attrs),
      actor: actor
    )
    |> Ash.create!()
  end

  defp create_assistant_message!(chat, parent, actor, attrs) do
    attrs = Enum.into(attrs, %{})

    ChatMessage
    |> Ash.Changeset.for_create(
      :add_message,
      Map.merge(
        %{
          chat_id: chat.id,
          role: :assistant,
          parent_id: parent.id,
          token_count: 0
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_item_with_text!(step_id, sequence, item_type, text, actor) do
    attrs =
      %{chat_message_step_id: step_id, sequence: sequence, type: item_type}
      |> maybe_put_tool_call_item_id(step_id, sequence, item_type, actor)

    item =
      ChatMessageItem
      |> Ash.Changeset.for_create(
        :create,
        attrs,
        actor: actor
      )
      |> Ash.create!()

    ChatMessageContent
    |> Ash.Changeset.for_create(
      :create,
      %{
        chat_message_item_id: item.id,
        sequence: 1,
        kind: :text,
        content_text: text
      },
      actor: actor
    )
    |> Ash.create!()

    item
  end

  defp maybe_put_tool_call_item_id(attrs, step_id, sequence, :tool_result, actor) do
    case preceding_tool_call_item(step_id, sequence, actor) do
      %ChatMessageItem{id: id} -> Map.put(attrs, :tool_call_item_id, id)
      _other -> attrs
    end
  end

  defp maybe_put_tool_call_item_id(attrs, _step_id, _sequence, _item_type, _actor), do: attrs

  defp preceding_tool_call_item(step_id, sequence, actor) do
    ChatMessageItem
    |> Ash.Query.filter(
      chat_message_step_id == ^step_id and type == :tool_call and sequence < ^sequence
    )
    |> Ash.Query.sort(sequence: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: actor)
  end

  defp create_item_with_text_and_opaque!(step_id, sequence, item_type, text, opaque, actor) do
    item = create_item_with_text!(step_id, sequence, item_type, text, actor)

    _ =
      ChatMessageContent
      |> Ash.Changeset.for_create(
        :create,
        %{
          chat_message_item_id: item.id,
          sequence: 2,
          kind: :opaque,
          content_json: opaque
        },
        actor: actor
      )
      |> Ash.create!()

    item
  end

  defp canceled_turn_aborted_marker do
    """
    <turn_aborted>
    The user interrupted the previous turn on purpose
    </turn_aborted>
    """
    |> String.trim()
  end

  defp error_turn_aborted_marker(error_text) do
    [
      "<turn_aborted>",
      "The move was interrupted due to an error.",
      to_string(error_text || "") |> String.trim(),
      "</turn_aborted>"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end
end
