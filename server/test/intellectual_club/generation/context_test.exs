defmodule IntellectualClub.Generation.ContextTest do
  @moduledoc """
  Behavior of `IntellectualClub.Generation.Context`: the generating message and
  initial provider request, the system prompt, tool exposure and binding
  resolution, and the provider history projected from canonical items.
  """

  use IntellectualClub.DataCase, async: false

  import ExUnit.CaptureLog
  import IntellectualClub.SqlCapture, only: [capture_queries: 1, selects_from: 2, reading: 2]

  require Ash.Query

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.{Bot, BotKnowledgeBlock}
  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageItem, ChatMessageStep, Threads}
  alias IntellectualClub.Files
  alias IntellectualClub.Generation.{Context, StepRequests, SystemPrompt}
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Knowledge.KnowledgeBlockFile
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Secrets.{DriverSecrets, KnowledgeBlockSecret, Secret}
  alias IntellectualClub.Tools.{BindingResolver, BotUserToolBinding, ToolFunction}

  @missing_user_message_placeholder "<There is no user message yet, you should write first>"
  @canceled_marker "<turn_aborted>\nThe user interrupted the previous turn on purpose\n</turn_aborted>"
  @error_marker "<turn_aborted>\nThe move was interrupted due to an error.\nProvider timeout\n</turn_aborted>"

  describe "build!/2 generation message and initial request" do
    test "keeps pure chat history when no bot is selected" do
      %{user: actor} = user_fixture()
      chat = chat_with_input!(actor, %{}, "Only history")

      context = build!(chat, actor)

      assert context.bot_id == nil
      assert context.system_prompt == ""
      assert context.messages == [%{"role" => "user", "content" => "Only history"}]
    end

    test "creates the generating assistant message and its initial step together" do
      %{user: actor} = user_fixture()
      chat = chat_with_input!(actor, %{}, "Only history")

      context = build!(chat, actor)

      assert is_integer(context.message_id)
      assert is_integer(context.step_id)
      message = Ash.get!(ChatMessage, context.message_id, actor: actor, load: [:chat, :steps])
      steps = Enum.sort_by(message.steps || [], & &1.sequence)

      assert message.status == :generating
      assert message.chat.last_message_id == message.id
      assert Enum.map(steps, & &1.id) == [context.step_id]

      [step] = steps
      assert step.chat_message_id == context.message_id
      assert step.sequence == 1
      assert step.status == :waiting_provider
      assert StepRequests.request_for_step!(step.id, actor: actor) == context.request_payload
      assert step.finished_at == nil
    end

    test "fixes canonical history before building the initial provider request" do
      %{user: actor} = user_fixture()

      configuration =
        create_configuration!(actor,
          provider_attrs: %{name: "OpenRouter role fix", type: :openrouter_chat_completion},
          model_name: "openai/gpt-5-mini",
          context_length: nil,
          fix_role_alteration: true
        )

      chat = create_chat!(actor, llm_configuration_id: configuration.id)

      for text <- ["Synthetic first turn", "Synthetic second turn"] do
        {:ok, _assistant} =
          Threads.add_message_to_end(chat, :assistant, text,
            actor: actor,
            llm_configuration_id: configuration.id
          )
      end

      context = build!(chat, actor)

      assert context.fix_role_alteration == true

      assert context.request_payload["messages"] == [
               %{"role" => "user", "content" => @missing_user_message_placeholder},
               %{"role" => "assistant", "content" => "Synthetic first turn"},
               %{"role" => "assistant", "content" => "Synthetic second turn"},
               %{"role" => "user", "content" => @missing_user_message_placeholder}
             ]
    end

    test "projects standard parameters before building and persisting the initial request" do
      %{user: actor} = user_fixture()

      configuration =
        create_configuration!(actor,
          provider_attrs: %{type: :responses, base_url: "https://api.openai.com/v1"},
          model_name: "gpt-5",
          context_length: nil,
          parameters: %{
            "temperature" => 1.6,
            "reasoning" => %{"effort" => "high", "summary" => "auto"},
            "max_tokens" => 64
          },
          temperature: 0.2,
          reasoning_effort: :minimal,
          web_search_enabled: true,
          cold_input_price_per_million_tokens: 1.25,
          cached_input_price_per_million_tokens: 0.25,
          output_price_per_million_tokens: 5.0
        )

      chat = chat_with_input!(actor, %{llm_configuration_id: configuration.id}, "Think briefly")

      context = build!(chat, actor)

      assert context.parameters == %{
               "temperature" => 0.2,
               "reasoning" => %{"effort" => "minimal", "summary" => "auto"},
               "max_tokens" => 64,
               "tools" => [%{"type" => "web_search"}]
             }

      assert context.request_payload["temperature"] == 0.2
      assert context.request_payload["reasoning"] == %{"effort" => "minimal", "summary" => "auto"}
      assert context.request_payload["max_output_tokens"] == 64
      assert context.request_payload["tools"] == [%{"type" => "web_search"}]
      assert context.cold_input_price_per_million_tokens == 1.25
      assert context.cached_input_price_per_million_tokens == 0.25
      assert context.output_price_per_million_tokens == 5.0

      step = Ash.get!(ChatMessageStep, context.step_id, actor: actor)
      assert StepRequests.request_for_step!(step.id, actor: actor) == context.request_payload
    end

    test "routing affinity follows nested spawn, fork and handoff lineage" do
      %{user: actor} = user_fixture()
      configuration = create_typed_configuration!(actor, :openrouter_chat_completion)
      root = create_empty_chat!(actor, llm_configuration_id: configuration.id, note: "Root")

      [spawn, fork, handoff] =
        Enum.scan([:spawn, :fork, :handoff], root, fn kind, parent ->
          create_subchat!(actor, parent, kind, llm_configuration_id: configuration.id)
        end)

      for chat <- [root, spawn, fork, handoff] do
        {:ok, _message} = Threads.add_message_to_end(chat, :user, "Continue", actor: actor)
        context = build!(chat, actor)

        assert context.owner_id == actor.id
        assert context.chat_id == chat.id
        assert context.conversation_affinity_id == root.id
        assert context.request_payload["session_id"] == "intellectual-club:chat:#{root.id}"
      end
    end

    test "builds the context up to the selected parent when parent_id is given" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)
      {:ok, root} = Threads.add_message_to_end(chat, :user, "Root", actor: actor)

      {:ok, assistant_a} =
        Threads.add_message(chat, :assistant, "A", actor: actor, parent_id: root.id)

      {:ok, _assistant_b} =
        Threads.add_message(chat, :assistant, "B", actor: actor, parent_id: root.id)

      context = build!(chat, actor, parent_id: root.id)

      assert context.history == [%{role: :user, content: "Root"}]
      assert context.messages == [%{"role" => "user", "content" => "Root"}]

      generating_message = Ash.get!(ChatMessage, context.message_id, actor: actor)
      assert generating_message.parent_id == root.id
      assert generating_message.status == :generating
      assert Ash.get!(Chat, chat.id, actor: actor).last_message_id == generating_message.id
      assert assistant_a.id != generating_message.id
    end

    test "uses the missing provider adapter for provider types unavailable in the build" do
      %{user: actor} = user_fixture()
      provider = create_provider!(actor, name: "Legacy provider")

      Ecto.Adapters.SQL.query!(Repo, "UPDATE llm_providers SET type = $1 WHERE id = $2", [
        "missing_provider_type",
        provider.id
      ])

      configuration =
        create_configuration!(actor,
          provider: provider,
          model_name: "legacy-model",
          context_length: 8192
        )

      chat = chat_with_input!(actor, %{llm_configuration_id: configuration.id}, "hello")

      context = build!(chat, actor)

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

    test "reads history steps without their raw request and response payloads" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)
      {:ok, _root} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)
      {:ok, assistant} = Threads.add_message_to_end(chat, :assistant, "answer", actor: actor)

      create_step!(actor, assistant,
        sequence: 2,
        raw_request: %{"blob" => String.duplicate("x", 1_000)},
        raw_response: %{"ok" => true}
      )

      {context, queries} = capture_queries(fn -> build!(chat, actor) end)
      step_reads = selects_from(queries, "chat_message_steps")

      assert context.messages == [
               %{"role" => "user", "content" => "hello"},
               %{"role" => "assistant", "content" => "answer"}
             ]

      assert step_reads != []
      assert reading(step_reads, "raw_request") == []
      assert reading(step_reads, "raw_response") == []
    end

    test "the demo provider turns the built request into one persisted final answer" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)
      Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")
      {:ok, _user_message} = Threads.add_message_to_end(chat, :user, "Hello", actor: actor)

      {:ok, context} =
        GenerationSupervisor.start_generation(chat.id, actor: actor, chunk_delay_ms: 0)

      message_id = context.message_id
      assert_receive {:done, ^message_id}, 1_000
      wait_for_message_status!(message_id, actor, :done)
      wait_for_generation_worker_to_stop!(message_id)
      refute_received {:done, ^message_id}

      message =
        Ash.get!(ChatMessage, message_id, actor: actor, load: [steps: [items: [:contents]]])

      assert message_answer_text(message) =~ "You said: Hello"
      assert [%{sequence: 1, items: [%{type: :answer, contents: contents}]}] = message.steps
      assert Enum.any?(contents, &(&1.kind == :text))
    end
  end

  describe "system prompt" do
    test "renders enabled bot blocks in binding order with files and secret descriptions" do
      %{user: actor} = user_fixture()
      first_block = create_knowledge_block!(actor, name: "First block", content: "First content")

      second_block =
        create_knowledge_block!(actor, name: "Second block", content: "Second content")

      first_block_file =
        create_block_file!(actor, first_block, "first-context.txt", "first block file")

      disabled_block_file =
        create_block_file!(actor, first_block, "disabled-context.txt", "disabled block file",
          enabled: false,
          sequence: 1
        )

      prompt_secret =
        create!(
          Secret,
          %{
            name: "Prompt token",
            description: "Token for the example API",
            value: "never-in-prompt"
          },
          actor
        )

      prompt_secret_binding =
        create!(
          KnowledgeBlockSecret,
          %{
            knowledge_block_id: first_block.id,
            secret_id: prompt_secret.id,
            env_name: "EXAMPLE_API_TOKEN"
          },
          actor
        )

      bot = create_bot!(actor, history_mode: :agent)
      bind_bot_block!(actor, bot, second_block, 20)
      bind_bot_block!(actor, bot, first_block, 10)
      chat = create_chat!(actor, bot_id: bot.id)
      {:ok, _} = Threads.add_message_to_end(chat, :user, "First question", actor: actor)
      {:ok, _} = Threads.add_message_to_end(chat, :user, "Second question", actor: actor)

      {context, log} = with_log(fn -> build!(chat, actor) end)

      refute log =~ "notifications in action IntellectualClub.Chat.ChatMessage"
      assert context.bot_id == bot.id
      assert context.history_mode == :agent
      assert Regex.match?(~r/# First block.*# Second block/s, context.system_prompt)
      assert context.system_prompt =~ "First content"
      assert context.system_prompt =~ "Second content"
      assert context.system_prompt =~ "[Attached file file_id=#{first_block_file.external_id}"
      refute context.system_prompt =~ disabled_block_file.external_id
      assert first_block_file.external_id in context.available_file_external_ids
      refute disabled_block_file.external_id in context.available_file_external_ids
      assert context.system_prompt =~ "`EXAMPLE_API_TOKEN`"
      assert context.system_prompt =~ "Token for the example API"
      refute context.system_prompt =~ "never-in-prompt"
      assert prompt_secret_binding.external_id in context.available_secret_binding_external_ids

      assert context.messages == [
               %{"role" => "system", "content" => context.system_prompt},
               %{"role" => "user", "content" => "First question"},
               %{"role" => "user", "content" => "Second question"}
             ]
    end

    test "orders config top, bot, chat, config bottom and user blocks without rendering placeholders" do
      %{user: actor} = user_fixture()

      [top, bot_block, chat_block, bottom, default_bottom, user_block] =
        for {name, content} <- [
              {"Config top", "config-top"},
              {"Bot block", "Bot says x={{x}} y={{y}} z={{z}}"},
              {"Chat block", "Chat says x={{x}} y={{y}}"},
              {"Config bottom", "config-bottom"},
              {"Config default", "Config says x={{x}} y={{y}} z={{z}}"},
              {"User block", "user"}
            ] do
          create_knowledge_block!(actor, name: name, content: content)
        end

      bot = create_bot!(actor)
      bind_bot_block!(actor, bot, bot_block, 10)
      configuration = create_configuration!(actor, model_name: "demo", context_length: 1024)
      bind_config_block!(actor, configuration, top, sequence: 5, selection: :top)
      bind_config_block!(actor, configuration, bottom, sequence: 30, selection: :bottom)
      bind_config_block!(actor, configuration, default_bottom, sequence: 35)
      chat = create_chat!(actor, bot_id: bot.id, llm_configuration_id: configuration.id)
      create_chat_block_binding!(actor, chat, chat_block, sequence: 20)
      create!(UserKnowledgeBlock, %{knowledge_block_id: user_block.id, sequence: 40}, actor)
      {:ok, _} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

      context = build!(chat, actor)
      snapshot = Context.prompt_snapshot!(chat.id, actor: actor)

      assert Regex.match?(
               ~r/# Config top.*# Bot block.*# Chat block.*# Config bottom.*# Config default.*# User block/s,
               context.system_prompt
             )

      for content <- [
            "Bot says x={{x}} y={{y}} z={{z}}",
            "Chat says x={{x}} y={{y}}",
            "Config says x={{x}} y={{y}} z={{z}}"
          ] do
        assert context.system_prompt =~ content
      end

      assert snapshot.system_prompt == context.system_prompt

      assert Enum.map(snapshot.prompt_blocks, &{&1.knowledge_block.name, &1.source}) == [
               {"Config top", :config},
               {"Bot block", :bot},
               {"Chat block", :chat},
               {"Config bottom", :config},
               {"Config default", :config},
               {"User block", :user}
             ]

      assert Enum.map(snapshot.prompt_blocks, & &1.prompt_order) == [0, 1, 2, 3, 4, 5]

      assert context.messages == [
               %{"role" => "system", "content" => context.system_prompt},
               %{"role" => "user", "content" => "hello"}
             ]
    end

    test "SystemPrompt.build/1 strips comment lines, keeps placeholders and appends enabled files" do
      report = prompt_file_binding("report.pdf", "application/pdf", 42, sequence: 0)
      disabled = prompt_file_binding("disabled.pdf", "application/pdf", 84, enabled: false)

      prompt =
        SystemPrompt.build(
          bot_blocks: [
            %{
              name: "Commented block",
              content: "{{dynamic_line}}\n//// remove this line\nVisible {{name}}"
            },
            %{
              name: "Files block",
              content: "//// hidden note\nVisible {{file_name}}",
              file_bindings: [report, disabled]
            }
          ]
        )

      assert prompt =~ "{{dynamic_line}}"
      assert prompt =~ "Visible {{name}}"
      refute prompt =~ "remove this line"
      refute prompt =~ "hidden note"

      assert prompt =~
               "Visible {{file_name}}\n[Attached file file_id=#{report.file.external_id} " <>
                 "filename=\"report.pdf\" mime_type=\"application/pdf\" size_bytes=42]"

      refute prompt =~ disabled.file.external_id
    end

    test "SystemPrompt.build/1 renders an attachment-only block as a valid section" do
      binding = prompt_file_binding("data.csv", "text/csv", 12, sequence: 0)

      prompt =
        SystemPrompt.build(
          bot_blocks: [%{name: "", content: "//// only a comment", file_bindings: [binding]}]
        )

      assert prompt ==
               "[Attached file file_id=#{binding.file.external_id} filename=\"data.csv\" " <>
                 "mime_type=\"text/csv\" size_bytes=12]\n\n---"
    end
  end

  describe "tool exposure" do
    test "includes fixed driver functions in the tools payload without discovery" do
      %{user: actor} = user_fixture()
      bot = create_bot!(actor)
      tool = search_tool!(actor, "Brave Search", "web")
      create_bot_tool_binding!(actor, bot, tool, sequence: 10)
      chat = chat_with_input!(actor, %{bot_id: bot.id}, "Search for Elixir")

      context = build!(chat, actor)

      context_tool = context.tool_instances_by_alias["web"]
      assert context_tool.id == tool.id
      assert context_tool.secrets == %{}
      assert {:ok, hydrated_tool} = DriverSecrets.hydrate(context_tool, query?: false)
      assert hydrated_tool.secrets == %{"brave_api_key" => "Brave Search-token"}
      assert "web__web_search" in tool_payload_names(context)
    end

    test "appends synthetic tool context grouped by active tool instance" do
      %{user: actor} = user_fixture()
      bot = create_bot!(actor)

      staging_tool =
        create_tool_instance!(actor,
          type: "ssh",
          name: "Staging SSH",
          description: "Staging server.\nUse for staging checks.\nLiteral {{tool_target}}.",
          alias: "staging_ssh",
          config: %{"host" => "staging.example.com", "username" => "deploy"}
        )

      prod_tool = search_tool!(actor, "Production Search", "prod_web")

      create_tool_function!(actor, staging_tool,
        name: "upload_file",
        description: "Disabled upload override",
        enabled: false
      )

      create_bot_tool_binding!(actor, bot, staging_tool, sequence: 10)
      create_bot_tool_binding!(actor, bot, prod_tool, sequence: 20)
      chat = chat_with_input!(actor, %{bot_id: bot.id}, "Check staging")

      context = build!(chat, actor)
      snapshot = Context.prompt_snapshot!(chat.id, actor: actor)
      prompt = context.system_prompt

      assert snapshot.system_prompt == prompt

      for fragment <- [
            "# Available tool instances\nThe available tools are grouped by tool instance.",
            "Tool names have the form `<tool_alias>__<function_name>`.",
            "## Tool instance `staging_ssh`",
            "Display name: Staging SSH",
            "Type: SSH (ssh)",
            "Type description: Execute remote commands on an SSH host.\n\n### Available functions\n- `",
            "`staging_ssh__run_command`",
            "### Instance description\nStaging server.",
            "Literal {{tool_target}}.",
            "## Tool instance `prod_web`",
            "`prod_web__web_search`"
          ] do
        assert prompt =~ fragment
      end

      refute prompt =~ "staging_ssh__upload_file"
      assert "staging_ssh__run_command" in tool_payload_names(context)
      refute "staging_ssh__upload_file" in tool_payload_names(context)
    end

    test "places synthetic tool context and routing keys in provider-specific fields" do
      %{user: actor} = user_fixture()
      bot = create_bot!(actor)
      tool = search_tool!(actor, "Provider Search", "provider_web")
      create_bot_tool_binding!(actor, bot, tool, sequence: 10)

      for provider_type <- [:openrouter_chat_completion, :responses] do
        configuration = create_typed_configuration!(actor, provider_type)
        attrs = %{bot_id: bot.id, llm_configuration_id: configuration.id}
        chat = chat_with_input!(actor, attrs, "Search")
        payload = build!(chat, actor).request_payload

        {system_text, routing_key, expected_routing_key} =
          case provider_type do
            :openrouter_chat_completion ->
              [%{"role" => "system", "content" => content} | _] = payload["messages"]
              {content, payload["session_id"], "intellectual-club:chat:#{chat.id}"}

            :responses ->
              {payload["instructions"], payload["prompt_cache_key"],
               "intellectual-club:user:#{actor.id}"}
          end

        assert system_text =~ "# Available tool instances"
        assert system_text =~ "`provider_web__web_search`"
        assert routing_key == expected_routing_key
      end
    end

    test "synthetic tool context includes outlet runner instance context when online" do
      Runtime.reset!()
      on_exit(&Runtime.reset!/0)

      %{user: actor} = user_fixture()
      bot = create_bot!(actor)

      tool =
        create_tool_instance!(actor,
          type: "outlet",
          name: "Shell Outlet",
          description: "Local shell runner.",
          alias: "shell",
          secrets: %{"token" => "runner-token"}
        )

      create_tool_function!(actor, tool, name: "run_command", description: "Run a shell command.")

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

      create_bot_tool_binding!(actor, bot, tool, sequence: 10)
      chat = chat_with_input!(actor, %{bot_id: bot.id}, "Run pwd")

      prompt = build!(chat, actor).system_prompt

      assert prompt =~ "## Tool instance `shell`"
      assert prompt =~ "`shell__run_command`"
      assert prompt =~ "### Instance context\nRunner hostname: dev-host"
      assert prompt =~ "Runner platform: macos"
      assert prompt =~ "Runner shell: /bin/zsh -c (kind: zsh)"
    end

    test "omits disabled fixed driver functions and restores them when re-enabled" do
      %{user: actor} = user_fixture()
      bot = create_bot!(actor)
      tool = search_tool!(actor, "Fixed Search", "web")
      create_bot_tool_binding!(actor, bot, tool, sequence: 10)

      override =
        create_tool_function!(actor, tool,
          name: "web_search",
          description: "Persisted override",
          enabled: false
        )

      chat = chat_with_input!(actor, %{bot_id: bot.id}, "Search for Elixir")

      refute "web__web_search" in tool_payload_names(build!(chat, actor))

      override
      |> Ash.Changeset.for_update(:update, %{enabled: true}, actor: actor)
      |> Ash.update!(actor: actor)

      assert "web__web_search" in tool_payload_names(build!(chat, actor))
    end

    test "fixed tool functions honor enabled_by_default and explicit overrides" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)
      agent_tool = create_tool_instance!(actor, type: "native-agent-management", alias: "agent")
      create_chat_tool_binding!(actor, chat, agent_tool)

      names = chat |> BindingResolver.resolve_for_chat(actor) |> tool_payload_names()

      assert "agent__handoff" in names
      assert "agent__sleep" in names
      refute "agent__fork" in names

      function_override!(actor, agent_tool, name: "fork", parameters_schema: %{})

      assert "agent__fork" in tool_payload_names(BindingResolver.resolve_for_chat(chat, actor))
    end

    test "subchats without inherited history omit functions rejected by subchat policy" do
      %{user: actor} = user_fixture()
      root = create_empty_chat!(actor)
      spawn_child = create_subchat!(actor, root, :spawn)
      fork_child = create_subchat!(actor, root, :fork)

      agent_tool =
        create_tool_instance!(actor,
          type: "native-agent-management",
          alias: "agent",
          config: %{"nested_subchats_limit" => 0}
        )

      for name <- ~w(fork fork_background spawn spawn_background check_background_task_status) do
        function_override!(actor, agent_tool, name: name)
      end

      for chat <- [root, spawn_child, fork_child] do
        create_chat_tool_binding!(actor, chat, agent_tool)
      end

      for chat <- [root, fork_child] do
        resolution = BindingResolver.resolve_for_chat(chat, actor)

        assert tool_payload_names(resolution) ==
                 Enum.map(
                   ~w(handoff fork fork_background spawn spawn_background check_background_task_status sleep),
                   &"agent__#{&1}"
                 )

        assert resolution.tool_context =~ "`agent__spawn`"
      end

      resolution = BindingResolver.resolve_for_chat(spawn_child, actor)

      assert tool_payload_names(resolution) == [
               "agent__check_background_task_status",
               "agent__sleep"
             ]

      refute resolution.tool_context =~ "`agent__spawn`"
      refute resolution.tool_context =~ "`agent__handoff`"

      assert BindingResolver.unavailable_function_names(
               %{"agent" => agent_tool},
               fork_child,
               actor
             ) ==
               Enum.map(~w(handoff fork fork_background spawn spawn_background), &"agent__#{&1}")
    end

    test "fixed background functions require an enabled status provider" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)

      ssh =
        create_tool_instance!(actor,
          type: "ssh",
          alias: "ssh",
          config: %{"host" => "example.com", "username" => "root"},
          secrets: %{"password" => "secret"}
        )

      agent = create_tool_instance!(actor, type: "native-agent-management", alias: "agent")
      background_override = function_override!(actor, ssh, name: "run_command_background")

      status_override =
        function_override!(actor, agent, name: "check_background_task_status", enabled: false)

      create_chat_tool_binding!(actor, chat, ssh, sequence: 0)
      create_chat_tool_binding!(actor, chat, agent, sequence: 1)

      resolution = BindingResolver.resolve_for_chat(chat, actor)
      names = tool_payload_names(resolution)

      assert "ssh__run_command" in names
      refute "ssh__run_command_background" in names
      refute "agent__check_background_task_status" in names
      assert resolution.tool_context =~ "`ssh__run_command`"
      refute resolution.tool_context =~ "`ssh__run_command_background`"

      assert %{"ssh" => true, "agent" => false} ==
               Map.new(
                 resolution.effective_tool_bindings,
                 &{&1.alias, &1.background_functions_unavailable}
               )

      assert Ash.get!(ToolFunction, background_override.id, actor: actor).enabled == true

      set_function_enabled!(status_override, true, actor)
      resolution = BindingResolver.resolve_for_chat(chat, actor)
      names = tool_payload_names(resolution)

      assert "ssh__run_command_background" in names
      assert "agent__check_background_task_status" in names
      assert resolution.tool_context =~ "`ssh__run_command_background`"
      refute Enum.any?(resolution.effective_tool_bindings, & &1.background_functions_unavailable)
    end

    test "stored background classification does not depend on function names" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)

      shadowed_status_provider =
        create_tool_instance!(actor, type: "native-agent-management", alias: "ops")

      function_override!(actor, shadowed_status_provider, name: "check_background_task_status")

      outlet =
        create_tool_instance!(actor,
          type: "outlet",
          alias: "ops",
          secrets: %{"token" => "stored-background-token"}
        )

      direct_function =
        function_override!(actor, outlet,
          name: "ordinary_background",
          description: "A direct function whose name ends in _background."
        )

      background_function =
        function_override!(actor, outlet,
          name: "enqueue_work",
          description: "A background function without a special suffix.",
          execution_mode: :background,
          target_function_name: "ordinary_background"
        )

      name_only_status_function =
        function_override!(actor, outlet,
          name: "check_background_task_status",
          description: "A regular stored function with a provider-like name."
        )

      create_chat_tool_binding!(actor, chat, shadowed_status_provider, sequence: 0)
      create_chat_tool_binding!(actor, chat, outlet, sequence: 10)

      resolution = BindingResolver.resolve_for_chat(chat, actor)
      names = tool_payload_names(resolution)

      assert "ops__ordinary_background" in names
      assert "ops__check_background_task_status" in names
      refute "ops__enqueue_work" in names
      assert resolution.tool_context =~ "`ops__ordinary_background`"
      refute resolution.tool_context =~ "`ops__enqueue_work`"

      assert [%{alias: "ops", background_functions_unavailable: true}] =
               Enum.map(
                 resolution.effective_tool_bindings,
                 &Map.take(&1, [:alias, :background_functions_unavailable])
               )

      assert Ash.get!(ToolFunction, background_function.id, actor: actor).enabled == true

      for function <- [direct_function, name_only_status_function] do
        set_function_enabled!(function, false, actor)
      end

      resolution = BindingResolver.resolve_for_chat(chat, actor)

      assert resolution.tools_payload == []
      assert resolution.tool_context == ""
      assert resolution.artifact_tools_available == false

      active_status_provider =
        create_tool_instance!(actor, type: "native-agent-management", alias: "agent")

      function_override!(actor, active_status_provider, name: "check_background_task_status")
      create_chat_tool_binding!(actor, chat, active_status_provider, sequence: 20)

      resolution = BindingResolver.resolve_for_chat(chat, actor)
      names = tool_payload_names(resolution)

      assert "ops__enqueue_work" in names
      assert "agent__check_background_task_status" in names
      assert resolution.tool_context =~ "`ops__enqueue_work`"
      assert resolution.artifact_tools_available == true
      refute Enum.any?(resolution.effective_tool_bindings, & &1.background_functions_unavailable)
    end

    test "unavailable discovered background wrappers are not model-visible" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)

      outlet =
        create_tool_instance!(actor,
          type: "outlet",
          alias: "outlet",
          secrets: %{"token" => "capability-downgrade-token"}
        )

      function_override!(actor, outlet, name: "run_command", description: "Run a command.")

      function_override!(actor, outlet,
        name: "run_command_background",
        description: "Run a command in the background.",
        discovery_available: false,
        execution_mode: :background,
        target_function_name: "run_command"
      )

      create_chat_tool_binding!(actor, chat, outlet)

      names = chat |> BindingResolver.resolve_for_chat(actor) |> tool_payload_names()

      assert "outlet__run_command" in names
      refute "outlet__run_command_background" in names
    end
  end

  describe "tool binding resolution" do
    for {name, specs, winners, expected} <- [
          {"a chat binding shadows a bot binding with the same alias",
           [{:bot, :search, "web", %{sequence: 10}}, {:chat, :search, "web", %{sequence: 0}}],
           %{"web" => 1}, [{"web", :chat, 0}]},
          {"a user bot binding shadows the creator binding with the same alias",
           [{:bot, :search, "web", %{sequence: 100}}, {:user, :search, "web", %{sequence: 1}}],
           %{"web" => 1}, [{"web", :user, 1}]},
          {"a higher sequence shadows a lower one at the same source priority",
           [{:chat, :search, "web", %{sequence: 10}}, {:chat, :search, "web", %{sequence: 20}}],
           %{"web" => 1}, [{"web", :chat, 20}]},
          {"chat and bot bindings with distinct aliases are both effective",
           [{:bot, :search, "bot_web", %{sequence: 0}}, {:chat, :search, "web", %{sequence: 0}}],
           %{"bot_web" => 0, "web" => 1}, [{"bot_web", :bot, 0}, {"web", :chat, 0}]}
        ] do
      test name do
        %{user: actor} = user_fixture()
        {chat, tools} = chat_with_bindings!(actor, unquote(Macro.escape(specs)))
        {:ok, _} = Threads.add_message_to_end(chat, :user, "Find docs", actor: actor)

        context = build!(chat, actor)

        for {alias_value, index} <- unquote(Macro.escape(winners)) do
          assert context.tool_instances_by_alias[alias_value].id == Enum.at(tools, index).id
        end

        assert "web__web_search" in tool_payload_names(context)
        resolution = BindingResolver.resolve_for_chat(chat, actor)

        assert resolution.effective_tool_bindings
               |> Enum.map(&{&1.alias, &1.source, &1.sequence})
               |> Enum.sort() == unquote(Macro.escape(expected))
      end
    end

    for {name, specs, expected} <- [
          {"an effective bot artifact reader", [{:bot, :artifact, "files", %{sequence: 10}}],
           true},
          {"effective bot and chat artifact readers",
           [{:bot, :artifact, "files", %{sequence: 10}}, {:chat, :artifact, "chat_files", %{}}],
           true},
          {"a user artifact reader overriding a per-user bot binding",
           [
             {:bot, :search, "files", %{sharing_mode: :per_user, sequence: 10}},
             {:user, :artifact, "files", %{sequence: 1}}
           ], true},
          {"a bot artifact reader shadowed by a chat tool",
           [{:bot, :artifact, "web", %{sequence: 10}}, {:chat, :search, "web", %{}}], false},
          {"a disabled chat artifact binding", [{:chat, :artifact, "files", %{enabled: false}}],
           false},
          {"an artifact reader whose functions are all disabled",
           [{:chat, :functionless_artifact, "files", %{}}], false}
        ] do
      test "artifact_tools_available is #{expected} for #{name}" do
        %{user: actor} = user_fixture()
        {chat, _tools} = chat_with_bindings!(actor, unquote(Macro.escape(specs)))

        assert BindingResolver.resolve_for_chat(chat, actor).artifact_tools_available ==
                 unquote(expected)
      end
    end
  end

  describe "provider history projection" do
    for format <- [:chat_completions, :responses] do
      test "#{format} history keeps canonical answers and tool items, drops reasoning and retried errors" do
        format = unquote(format)
        %{user: actor} = user_fixture()
        {chat, assistant} = weather_chat!(actor, format)
        retry_step = create_step!(actor, assistant, sequence: 1, status: :error)

        text_item!(
          actor,
          retry_step,
          1,
          :error,
          "Transient provider error on attempt 1. Retrying.\n\nTemporary network outage"
        )

        step = create_step!(actor, assistant, sequence: 2)
        text_item!(actor, step, 1, :tool_call, "Tool call: weather__get", wire(format, :call))
        text_item!(actor, step, 2, :reasoning, "Hidden reasoning text", wire(format, :reasoning))
        text_item!(actor, step, 3, :tool_result, ~s({"temperature":18.5}), wire(format, :result))
        text_item!(actor, step, 4, :answer, "It is 18.5°C in Paris.", wire(format, :stale_answer))
        {:ok, _} = Threads.add_message_to_end(chat, :user, "And tomorrow?", actor: actor)

        context = build!(chat, actor)

        assert context.provider_type == provider_type_name(format)

        assert context.messages ==
                 [expected_user(format, "What's the weather?")] ++
                   expected_weather_exchange(format, "final_answer") ++
                   [expected_user(format, "And tomorrow?")]

        refute inspect(context.messages) =~ "Transient provider error"
        refute inspect(context.messages) =~ "Hidden reasoning text"
        assert request_history(format, context.request_payload) == context.messages
        assert context.request_payload["store"] == request_store(format)
      end

      for {interruption, message_attrs, marker} <- [
            {:canceled, %{status: :canceled}, @canceled_marker},
            {:error, %{status: :error, error_detail: "Provider timeout"}, @error_marker}
          ] do
        test "#{format} history keeps the completed prefix of a #{interruption} assistant message" do
          format = unquote(format)
          interruption = unquote(interruption)
          %{user: actor} = user_fixture()
          {chat, assistant} = weather_chat!(actor, format, unquote(Macro.escape(message_attrs)))
          completed = create_step!(actor, assistant, sequence: 1, status: :done)

          text_item!(
            actor,
            completed,
            1,
            :tool_call,
            "Tool call: weather__get",
            wire(format, :call)
          )

          text_item!(
            actor,
            completed,
            2,
            :tool_result,
            ~s({"temperature":18.5}),
            wire(format, :result)
          )

          text_item!(actor, completed, 3, :answer, "It is 18.5°C in Paris.")
          interrupted = create_step!(actor, assistant, sequence: 2, status: interruption)

          text_item!(actor, interrupted, 1, :answer, "Checking tomorrow.", %{
            "type" => "message",
            "role" => "assistant",
            "status" => "in_progress",
            "content" => []
          })

          text_item!(
            actor,
            interrupted,
            2,
            :tool_call,
            "Tool call: weather__get",
            wire(format, :tomorrow_call)
          )

          {:ok, _} = Threads.add_message_to_end(chat, :user, "And tomorrow?", actor: actor)

          context = build!(chat, actor)

          assert context.messages ==
                   [expected_user(format, "What's the weather?")] ++
                     expected_weather_exchange(format, "commentary") ++
                     [
                       expected_assistant(format, "Checking tomorrow.", "final_answer"),
                       expected_user(format, unquote(marker)),
                       expected_user(format, "And tomorrow?")
                     ]

          refute inspect(context.messages) =~ "call_tomorrow"
        end
      end
    end

    test "continuing from a canceled leaf appends the turn-aborted marker" do
      %{user: actor} = user_fixture()
      chat = create_chat!(actor)

      {:ok, user_message} =
        Threads.add_message_to_end(chat, :user, "Start a long answer", actor: actor)

      assistant =
        create_message!(actor, chat,
          parent_id: user_message.id,
          status: :canceled,
          token_count: 0
        )

      canceled_step = create_step!(actor, assistant, status: :canceled)
      text_item!(actor, canceled_step, 1, :answer, "Discard this partial")

      history = Context.history_for_generation!(chat.id, actor: actor, parent_id: assistant.id)

      assert Enum.take(history, -2) == [
               %{role: :assistant, content: "Discard this partial"},
               %{role: :user, content: @canceled_marker}
             ]
    end

    test "chat completions history uses a placeholder for an empty tool result" do
      %{user: actor} = user_fixture()

      configuration =
        create_typed_configuration!(actor, :openrouter_chat_completion,
          model_name: "anthropic/claude-opus-4.6"
        )

      chat = chat_with_input!(actor, %{llm_configuration_id: configuration.id}, "Run tool")

      {:ok, assistant} =
        Threads.add_message_to_end(chat, :assistant, "",
          actor: actor,
          llm_configuration_id: configuration.id
        )

      step = create_step!(actor, assistant, sequence: 2)

      text_item!(actor, step, 1, :tool_call, "Tool call: weather__get", %{
        "tool_call_id" => "call_empty_output",
        "name" => "weather__get",
        "arguments" => %{"city" => "Paris"},
        "raw" => %{
          "id" => "call_empty_output",
          "type" => "function",
          "function" => %{"name" => "weather__get", "arguments" => ~s({"city":"Paris"})}
        }
      })

      text_item!(actor, step, 2, :tool_result, "", %{
        "tool_call_id" => "call_empty_output",
        "name" => "weather__get",
        "raw" => %{}
      })

      {:ok, _user_2} = Threads.add_message_to_end(chat, :user, "Next", actor: actor)

      context = build!(chat, actor)

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
                     "function" => %{
                       "name" => "weather__get",
                       "arguments" => ~s({"city":"Paris"})
                     }
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

    test "applies cache control markers for supported chat configurations" do
      %{user: actor} = user_fixture()
      block = create_knowledge_block!(actor, name: "Prompt", content: "System guidance")
      bot = create_bot!(actor)
      bind_bot_block!(actor, bot, block, 10)

      configuration =
        create_typed_configuration!(actor, :openrouter_chat_completion,
          model_name: "anthropic/claude-sonnet-4",
          supports_cache_control: true
        )

      chat =
        chat_with_input!(
          actor,
          %{bot_id: bot.id, llm_configuration_id: configuration.id},
          "Hello"
        )

      context = build!(chat, actor)

      assert context.cache_control_enabled == true
      assert context.history_length == 2
      assert [system_message, user_message] = context.messages

      for {message, role} <- [{system_message, "system"}, {user_message, "user"}] do
        assert message["role"] == role
        assert is_list(message["content"])
        assert List.last(message["content"])["cache_control"] == %{"type" => "ephemeral"}
      end

      assert context.request_payload["messages"] == context.messages
    end

    test "bot history modes replay only canonical data with exact configuration identity" do
      %{user: actor} = user_fixture()
      provider = create_provider!(actor, type: :responses, base_url: "https://api.openai.com/v1")
      first = create_configuration!(actor, provider: provider, model_name: "same-model")
      second = create_configuration!(actor, provider: provider, model_name: "same-model")
      bot = create!(Bot, %{name: "History modes"}, actor)
      assert bot.history_mode == :agent

      assert {:error, _} =
               Bot
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "Invalid mode", history_mode: :unknown},
                 actor: actor
               )
               |> Ash.create(actor: actor)

      chat = create_chat!(actor, bot_id: bot.id, llm_configuration_id: first.id)
      {:ok, user} = Threads.add_message_to_end(chat, :user, "Question", actor: actor)

      assistant =
        create_message!(actor, chat,
          parent_id: user.id,
          llm_configuration_id: first.id,
          token_count: 0
        )

      step =
        create_step!(actor, assistant,
          raw_response: %{"encrypted_content" => "stale-raw-response"}
        )

      text_item!(actor, step, 1, :reasoning, "Visible summary", %{
        "type" => "reasoning",
        "summary" => [],
        "encrypted_content" => "canonical-reasoning"
      })

      text_item!(actor, step, 2, :answer, "Edited answer")
      text_item!(actor, step, 3, :steering, "User steering")
      {:ok, last_user} = Threads.add_message_to_end(chat, :user, "Continue", actor: actor)

      for {mode, config, expected} <- [
            {:agent, first, false},
            {:chat, first, false},
            {:full, first, true},
            {:full, second, false},
            {:full, first, true}
          ] do
        Ash.get!(Bot, bot.id, actor: actor)
        |> Ash.Changeset.for_update(:update, %{history_mode: mode}, actor: actor)
        |> Ash.update!(actor: actor)

        Ash.get!(Chat, chat.id, actor: actor)
        |> Ash.Changeset.for_update(:update, %{llm_configuration_id: config.id}, actor: actor)
        |> Ash.update!(actor: actor)

        {:ok, preparation} = Context.prepare(chat.id, actor: actor, parent_id: last_user.id)
        context = preparation.context
        input = Jason.encode!(context.messages)

        assert context.history_mode == mode
        assert String.contains?(input, "canonical-reasoning") == expected
        assert input =~ "Edited answer"
        assert input =~ "User steering"
        refute input =~ "stale-raw-response"
      end

      first
      |> Ash.Changeset.for_update(
        :update,
        %{model_name: "edited-model", parameters: %{"temperature" => 0.5}},
        actor: actor
      )
      |> Ash.update!(actor: actor)

      {:ok, preparation} = Context.prepare(chat.id, actor: actor, parent_id: last_user.id)
      assert inspect(preparation.context.request_payload) =~ "canonical-reasoning"
    end
  end

  defp build!(chat, actor, opts \\ []) do
    Context.build!(chat.id, Keyword.merge([actor: actor, chunk_delay_ms: 0], opts))
  end

  defp chat_with_input!(actor, attrs, text) do
    chat = create_chat!(actor, attrs)
    {:ok, _message} = Threads.add_message_to_end(chat, :user, text, actor: actor)
    chat
  end

  defp create_typed_configuration!(actor, provider_type, attrs \\ %{}) do
    base_url =
      if provider_type == :responses,
        do: "https://api.openai.com/v1",
        else: "https://openrouter.ai/api/v1"

    defaults = %{
      provider_attrs: %{type: provider_type, base_url: base_url},
      model_name: "test-model",
      note: nil,
      context_length: 8192
    }

    create_configuration!(actor, merge_attrs(defaults, attrs))
  end

  # Knowledge blocks

  defp create_block_file!(actor, block, filename, payload, attrs \\ %{}) do
    {:ok, file} = Files.create_from_binary(filename, "text/plain", payload)
    defaults = %{knowledge_block_id: block.id, file_id: file.id, sequence: 0}
    create!(KnowledgeBlockFile, merge_attrs(defaults, attrs), actor)
    file
  end

  defp bind_bot_block!(actor, bot, block, sequence) do
    attrs = %{bot_id: bot.id, knowledge_block_id: block.id, enabled: true, sequence: sequence}
    create!(BotKnowledgeBlock, attrs, actor)
  end

  defp bind_config_block!(actor, configuration, block, attrs) do
    defaults = %{
      llm_configuration_id: configuration.id,
      knowledge_block_id: block.id,
      enabled: true
    }

    create!(LlmConfigurationKnowledgeBlock, merge_attrs(defaults, attrs), actor)
  end

  defp prompt_file_binding(filename, mime_type, size_bytes, attrs) do
    id = System.unique_integer([:positive])

    file = %{
      id: id,
      external_id: Ash.UUID.generate(),
      filename: filename,
      mime_type: mime_type,
      size_bytes: size_bytes,
      sha256: String.duplicate("a", 64)
    }

    defaults = %{id: id, external_id: Ash.UUID.generate(), sequence: 1, file_id: id, file: file}
    merge_attrs(defaults, attrs)
  end

  # Tools

  defp search_tool!(actor, name, alias_value) do
    create_tool_instance!(actor,
      type: "native-web-search",
      name: name,
      alias: alias_value,
      secrets: %{"token" => "#{name}-token"}
    )
  end

  # A persisted function row that overrides or extends what the driver declares.
  defp function_override!(actor, tool, attrs) do
    defaults = %{parameters_schema: %{"type" => "object", "properties" => %{}}}

    create_tool_function!(actor, tool, merge_attrs(defaults, attrs))
  end

  defp set_function_enabled!(function, enabled, actor) do
    function
    |> Ash.Changeset.for_update(:update, %{enabled: enabled}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp tool_payload_names(%{tools_payload: tools_payload}) when is_list(tools_payload) do
    Enum.map(tools_payload, &get_in(&1, ["function", "name"]))
  end

  # Creates one tool per `{source, kind, alias, binding_attrs}` spec, binds bot and
  # user specs before the chat is created and chat specs after it. Returns the chat
  # and the tools in spec order.
  defp chat_with_bindings!(actor, specs) do
    tools =
      Enum.map(specs, fn {_source, kind, alias_value, _attrs} ->
        tool!(actor, kind, alias_value)
      end)

    bound = Enum.zip(specs, tools)

    {chat_specs, bot_specs} =
      Enum.split_with(bound, fn {{source, _, _, _}, _tool} -> source == :chat end)

    chat_attrs =
      case bot_specs do
        [] ->
          %{}

        _bot_specs ->
          bot = create_bot!(actor)

          for {{source, _kind, _alias, attrs}, tool} <- bot_specs do
            bind_tool!(actor, source, bot, tool, attrs)
          end

          %{bot_id: bot.id}
      end

    chat = create_chat!(actor, chat_attrs)

    for {{:chat, _kind, _alias, attrs}, tool} <- chat_specs do
      bind_tool!(actor, :chat, chat, tool, attrs)
    end

    {chat, tools}
  end

  defp tool!(actor, :search, alias_value),
    do: search_tool!(actor, unique_name("Search"), alias_value)

  defp tool!(actor, :artifact, alias_value) do
    create_tool_instance!(actor, type: "native-artifact-reader", alias: alias_value)
  end

  defp tool!(actor, :functionless_artifact, alias_value) do
    tool = tool!(actor, :artifact, alias_value)

    for name <- ~w(read_file search_file read_image upload_file) do
      function_override!(actor, tool, name: name, parameters_schema: %{}, enabled: false)
    end

    tool
  end

  defp bind_tool!(actor, :bot, bot, tool, attrs),
    do: create_bot_tool_binding!(actor, bot, tool, attrs)

  defp bind_tool!(actor, :chat, chat, tool, attrs),
    do: create_chat_tool_binding!(actor, chat, tool, attrs)

  defp bind_tool!(actor, :user, bot, tool, attrs) do
    defaults = %{bot_id: bot.id, tool_instance_id: tool.id, enabled: true, sequence: 0}
    create!(BotUserToolBinding, merge_attrs(defaults, attrs), actor)
  end

  # Provider history fixtures

  defp weather_chat!(actor, format, message_attrs \\ %{}) do
    {provider_type, model_name} =
      case format do
        :chat_completions -> {:openrouter_chat_completion, "openai/gpt-5-nano"}
        :responses -> {:responses, "gpt-5-nano"}
      end

    configuration = create_typed_configuration!(actor, provider_type, model_name: model_name)
    chat = create_chat!(actor, llm_configuration_id: configuration.id)
    {:ok, question} = Threads.add_message_to_end(chat, :user, "What's the weather?", actor: actor)

    defaults = %{parent_id: question.id, llm_configuration_id: configuration.id, token_count: 0}
    {chat, create_message!(actor, chat, merge_attrs(defaults, message_attrs))}
  end

  # Creates an item with one text content and, when given, an opaque provider
  # payload. A tool result is linked to the closest preceding tool call of the step.
  defp text_item!(actor, step, sequence, type, text, opaque \\ nil) do
    attrs =
      case type do
        :tool_result -> %{tool_call_item_id: preceding_tool_call_id(actor, step, sequence)}
        _other -> %{}
      end

    item = create_item!(actor, step, Map.merge(attrs, %{sequence: sequence, type: type}))
    create_content!(actor, item, content_text: text)

    if opaque do
      create_content!(actor, item, sequence: 2, kind: :opaque, content_json: opaque)
    end

    item
  end

  defp preceding_tool_call_id(actor, step, sequence) do
    ChatMessageItem
    |> Ash.Query.filter(
      chat_message_step_id == ^step.id and type == :tool_call and sequence < ^sequence
    )
    |> Ash.Query.sort(sequence: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: actor)
    |> case do
      nil -> nil
      item -> item.id
    end
  end

  defp wire(:chat_completions, :call), do: chat_tool_call("call_weather", ~s({"city":"Paris"}))

  defp wire(:chat_completions, :tomorrow_call),
    do: chat_tool_call("call_tomorrow", ~s({"city":"Paris","day":"tomorrow"}))

  defp wire(:chat_completions, :result) do
    %{
      "tool_call_id" => "call_weather",
      "name" => "weather__get",
      "raw" => %{"temperature" => 18.5}
    }
  end

  defp wire(:chat_completions, _reasoning_or_answer), do: nil
  defp wire(:responses, :call), do: responses_call("call_weather", ~s({"city":"Paris"}))

  defp wire(:responses, :tomorrow_call),
    do: responses_call("call_tomorrow", ~s({"city":"Paris","day":"tomorrow"}))

  defp wire(:responses, :result) do
    %{
      "type" => "function_call_output",
      "id" => "fco_call_weather",
      "call_id" => "call_weather",
      "output" => ~s({"temperature":18.5})
    }
  end

  defp wire(:responses, :reasoning) do
    %{
      "type" => "reasoning",
      "id" => "rs_123",
      "summary" => [%{"type" => "summary_text", "text" => "hidden"}]
    }
  end

  defp wire(:responses, :stale_answer) do
    expected_assistant(:responses, "The stale answer before editing.", "commentary")
  end

  defp chat_tool_call(id, arguments) do
    %{
      "tool_call_id" => id,
      "name" => "weather__get",
      "arguments" => Jason.decode!(arguments),
      "raw" => %{
        "id" => id,
        "type" => "function",
        "function" => %{"name" => "weather__get", "arguments" => arguments}
      }
    }
  end

  defp responses_call(call_id, arguments) do
    %{
      "type" => "function_call",
      "id" => "fc_#{call_id}",
      "call_id" => call_id,
      "name" => "weather__get",
      "arguments" => arguments
    }
  end

  defp provider_type_name(:chat_completions), do: "openrouter_chat_completion"
  defp provider_type_name(:responses), do: "responses"

  defp request_history(:chat_completions, payload), do: payload["messages"]
  defp request_history(:responses, payload), do: payload["input"]

  defp request_store(:chat_completions), do: nil
  defp request_store(:responses), do: false

  defp expected_user(:chat_completions, text), do: %{"role" => "user", "content" => text}

  defp expected_user(:responses, text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end

  defp expected_assistant(:chat_completions, text, _phase),
    do: %{"role" => "assistant", "content" => text}

  defp expected_assistant(:responses, text, phase) do
    %{
      "type" => "message",
      "role" => "assistant",
      "status" => "completed",
      "phase" => phase,
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }
  end

  defp expected_weather_exchange(:chat_completions, _phase) do
    [
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
      %{"role" => "tool", "tool_call_id" => "call_weather", "content" => ~s({"temperature":18.5})}
    ]
  end

  defp expected_weather_exchange(:responses, phase) do
    [
      wire(:responses, :call),
      wire(:responses, :result),
      expected_assistant(:responses, "It is 18.5°C in Paris.", phase)
    ]
  end
end
