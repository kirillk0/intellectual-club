defmodule IntellectualClub.Generation.Context do
  @moduledoc """
  Builds a self-contained context for generation.

  This is the only module in the generation subsystem that depends on Ash
  resources and queries.
  """

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.CacheControl
  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.RequestBuilder
  alias IntellectualClub.Generation.SystemPrompt
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Tools.BindingResolver

  require Ash.Query

  defstruct [
    :owner_id,
    :chat_id,
    :bot_id,
    :message_id,
    :step_id,
    :llm_configuration_id,
    :history_mode,
    :history,
    :system_prompt,
    :provider_id,
    :provider_type,
    :provider_base_url,
    :provider_api_key,
    :provider_auth_method,
    :provider_oauth_refresh_token,
    :model_name,
    :parameters,
    :timeout_ms,
    :context_length,
    :supports_image_input,
    :messages,
    :request_payload,
    :chunk_delay_ms,
    :tools_payload,
    :tool_instances_by_alias,
    :max_tool_rounds,
    :context_soft_limit_percent,
    :cache_control_enabled,
    :history_length,
    :initial_step_sequence
  ]

  def authorize_chat!(chat_id, actor) do
    _chat = Ash.get!(Chat, chat_id, actor: actor)
    :ok
  end

  def prepare_retry(message_id, opts \\ []) when is_integer(message_id) and is_list(opts) do
    actor = Keyword.get(opts, :actor)

    allowed_statuses =
      opts
      |> Keyword.get(:allowed_statuses, [:error, :canceled])
      |> normalize_allowed_statuses()

    with {:ok, message} <- load_retry_message(message_id, actor),
         :ok <- validate_retry_message(message, allowed_statuses),
         {:ok, retry_step} <- load_retry_step(message, opts),
         {:ok, request_payload} <- normalize_retry_request_payload(retry_step.raw_request),
         {:ok, chat} <- load_retry_chat(message),
         {:ok, llm_configuration} <- resolve_retry_configuration(message, chat, actor) do
      tool_resolution = BindingResolver.resolve_for_chat(chat, actor)
      tool_instances_by_alias = tool_resolution.tool_instances_by_alias

      tools_payload =
        maybe_disable_tools_for_retry(request_payload, tool_resolution.tools_payload)

      provider = llm_configuration && Map.get(llm_configuration, :provider)

      provider_id =
        case provider do
          %{} = value -> Map.get(value, :id)
          _other -> nil
        end

      provider_base_url =
        case provider do
          %{} = value -> Map.get(value, :base_url)
          _other -> nil
        end

      provider_api_key =
        case provider do
          %{} = value -> Map.get(value, :api_key)
          _other -> nil
        end

      provider_auth_method =
        case provider do
          %{} = value -> Map.get(value, :auth_method)
          _other -> nil
        end

      provider_oauth_refresh_token =
        case provider do
          %{} = value -> Map.get(value, :oauth_refresh_token)
          _other -> nil
        end

      context = %__MODULE__{
        owner_id: actor && actor.id,
        chat_id: chat.id,
        bot_id: chat.bot_id,
        message_id: message.id,
        llm_configuration_id: llm_configuration && llm_configuration.id,
        history_mode: :agent,
        history: [],
        system_prompt: payload_instructions(request_payload),
        provider_id: provider_id,
        provider_type: provider_type_for_configuration(llm_configuration),
        provider_base_url: provider_base_url,
        provider_api_key: provider_api_key,
        provider_auth_method: provider_auth_method,
        provider_oauth_refresh_token: provider_oauth_refresh_token,
        model_name: payload_model_name(request_payload, llm_configuration),
        parameters: payload_parameters(request_payload, llm_configuration),
        timeout_ms: configuration_timeout_ms(llm_configuration),
        context_length: configuration_context_length(llm_configuration),
        supports_image_input:
          bool_true?(llm_configuration && llm_configuration.supports_image_input),
        messages: payload_messages(request_payload),
        request_payload: request_payload,
        tools_payload: tools_payload,
        tool_instances_by_alias: tool_instances_by_alias,
        max_tool_rounds: max_tool_rounds_for_chat(chat),
        context_soft_limit_percent: context_soft_limit_percent_for_chat(chat),
        cache_control_enabled: false,
        history_length: nil,
        initial_step_sequence: retry_step.sequence,
        chunk_delay_ms:
          Keyword.get(
            opts,
            :chunk_delay_ms,
            Application.get_env(:intellectual_club, :demo_chunk_delay_ms, 40)
          )
      }

      {:ok, context}
    end
  end

  def build!(chat_id, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    chat =
      Ash.get!(Chat, chat_id,
        actor: actor,
        load: [:bot, :last_message, llm_configuration: [:provider]]
      )

    target_parent_id =
      case Keyword.fetch(opts, :parent_id) do
        {:ok, parent_id} when is_integer(parent_id) -> parent_id
        _other -> chat.last_message_id
      end

    source_branch =
      if is_integer(target_parent_id) do
        case Threads.branch_to_message(chat, target_parent_id, actor,
               load: [
                 steps: [
                   items: [
                     contents: [:file, :content_text, :content_json, :kind, :sequence]
                   ]
                 ]
               ]
             ) do
          {:ok, branch} -> branch
          {:error, :message_not_found} -> raise ArgumentError, "Parent message not found in chat"
        end
      else
        []
      end

    history = Enum.filter(source_branch, &(&1.status == :done))

    history_mode = :agent

    history_entries =
      Enum.map(history, fn message ->
        %{
          role: message.role,
          content: project_message_text(message)
        }
      end)

    bot_blocks = load_bot_blocks(chat.bot_id, actor)
    chat_blocks = load_chat_blocks(chat.id, actor)
    config_bindings = load_configuration_blocks(chat.llm_configuration_id, actor)
    {config_top_blocks, config_bottom_blocks} = split_configuration_blocks(config_bindings)
    user_blocks = load_user_blocks(actor)

    system_prompt =
      SystemPrompt.build(
        bot_blocks: bot_blocks,
        chat_blocks: chat_blocks,
        config_top_blocks: config_top_blocks,
        config_bottom_blocks: config_bottom_blocks,
        user_blocks: user_blocks,
        bot_variables: chat.bot && chat.bot.variables,
        chat_variables: chat.variables
      )

    provider_type = provider_type_for_chat(chat)

    supports_image_input =
      bool_true?(chat.llm_configuration && Map.get(chat.llm_configuration, :supports_image_input))

    history_messages =
      case provider_type do
        :responses ->
          # Responses providers use `instructions`, not `role=system` items.
          History.build_responses_input_items(history,
            supports_image_input: supports_image_input,
            provider_type: provider_type
          )

        _other ->
          History.build_chat_completions_history_messages(history,
            supports_image_input: supports_image_input,
            provider_type: provider_type
          )
      end

    messages_with_system =
      case provider_type do
        :responses ->
          history_messages

        _other ->
          if String.trim(system_prompt) == "" do
            history_messages
          else
            [%{"role" => "system", "content" => system_prompt} | history_messages]
          end
      end

    tool_resolution = BindingResolver.resolve_for_chat(chat, actor)
    tools_payload = tool_resolution.tools_payload
    tool_instances_by_alias = tool_resolution.tool_instances_by_alias

    {provider_id, provider_type, provider_base_url, provider_api_key, provider_auth_method,
     provider_oauth_refresh_token, model_name, parameters, timeout_ms, request_payload, messages,
     cache_control_enabled, history_length} =
      case chat.llm_configuration do
        nil ->
          {nil, :demo, nil, nil, nil, nil, nil, %{}, nil, nil, messages_with_system, false, nil}

        configuration ->
          provider = configuration.provider

          provider_id = provider.id
          provider_type = provider.type
          provider_base_url = provider.base_url
          provider_api_key = provider.api_key
          provider_auth_method = provider.auth_method
          provider_oauth_refresh_token = provider.oauth_refresh_token
          model_name = configuration.model_name
          parameters = configuration.parameters || %{}
          timeout_ms = max(1, configuration.timeout_seconds || 300) * 1000

          cache_control_enabled =
            provider_type != :responses and
              bool_true?(Map.get(configuration, :supports_cache_control))

          messages =
            if cache_control_enabled do
              history_length = length(messages_with_system)

              messages_with_system
              |> CacheControl.apply_system_prompt_marker()
              |> CacheControl.apply_history_end_marker(history_length: history_length)
            else
              messages_with_system
            end

          history_length =
            if cache_control_enabled do
              length(messages_with_system)
            else
              nil
            end

          request_payload =
            case provider_type do
              :responses ->
                RequestBuilder.build_responses_payload_from_input_items(
                  model_name,
                  parameters,
                  messages,
                  include: ["reasoning.encrypted_content"],
                  instructions: system_prompt,
                  tools: tools_payload
                )

              _other ->
                RequestBuilder.build_chat_completions_payload(model_name, parameters, messages,
                  tools: tools_payload
                )
            end

          {provider_id, provider_type, provider_base_url, provider_api_key, provider_auth_method,
           provider_oauth_refresh_token, model_name, parameters, timeout_ms, request_payload,
           messages, cache_control_enabled, history_length}
      end

    generating_message_params = %{
      chat_id: chat_id,
      parent_id: target_parent_id,
      llm_configuration_id: chat.llm_configuration_id,
      token_count: 0
    }

    generating_message =
      ChatMessage
      |> Ash.Changeset.for_create(:create_generating_assistant, generating_message_params,
        actor: actor
      )
      |> Ash.create!()

    %__MODULE__{
      owner_id: actor && actor.id,
      chat_id: chat_id,
      bot_id: chat.bot_id,
      message_id: generating_message.id,
      llm_configuration_id: chat.llm_configuration_id,
      history_mode: history_mode,
      history: history_entries,
      system_prompt: system_prompt,
      provider_id: provider_id,
      provider_type: provider_type,
      provider_base_url: provider_base_url,
      provider_api_key: provider_api_key,
      provider_auth_method: provider_auth_method,
      provider_oauth_refresh_token: provider_oauth_refresh_token,
      model_name: model_name,
      parameters: parameters,
      timeout_ms: timeout_ms,
      context_length: configuration_context_length(chat.llm_configuration),
      supports_image_input: supports_image_input,
      messages: messages,
      request_payload: request_payload,
      tools_payload: tools_payload,
      tool_instances_by_alias: tool_instances_by_alias,
      max_tool_rounds: max_tool_rounds_for_chat(chat),
      context_soft_limit_percent: context_soft_limit_percent_for_chat(chat),
      cache_control_enabled: cache_control_enabled,
      history_length: history_length,
      chunk_delay_ms:
        Keyword.get(
          opts,
          :chunk_delay_ms,
          Application.get_env(:intellectual_club, :demo_chunk_delay_ms, 40)
        )
    }
  end

  defp project_message_text(message) do
    role = Map.get(message, :role)

    wanted_type =
      case role do
        :user -> :input
        "user" -> :input
        :assistant -> :answer
        "assistant" -> :answer
        _ -> nil
      end

    steps = Map.get(message, :steps) || []

    steps
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn step ->
      items = Map.get(step, :items) || []
      items |> Enum.sort_by(&sort_seq/1)
    end)
    |> Enum.filter(fn item ->
      item_type = Map.get(item, :type)
      wanted_type != nil and item_type == wanted_type
    end)
    |> Enum.map(&item_text/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp item_text(item) do
    contents = Map.get(item, :contents) || []

    contents
    |> Enum.filter(fn content ->
      kind = Map.get(content, :kind)
      kind in [:text, "text"]
    end)
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.map(fn content -> to_string(Map.get(content, :content_text) || "") end)
    |> Enum.join("")
  end

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0

  defp bool_true?(value), do: value in [true, "true", 1]

  defp load_retry_message(message_id, actor) when is_integer(message_id) do
    load = [
      chat: [:bot, llm_configuration: [:provider]],
      llm_configuration: [:provider],
      steps: [items: [:contents]]
    ]

    case Ash.get(ChatMessage, message_id, actor: actor, load: load) do
      {:ok, message} -> {:ok, message}
      {:error, _error} -> {:error, :not_found}
    end
  end

  defp validate_retry_message(message, allowed_statuses)
       when is_map(message) and is_list(allowed_statuses) do
    role = Map.get(message, :role)

    if role in [:assistant, "assistant"] do
      status = Map.get(message, :status)
      normalized_status = normalize_status(status)

      if normalized_status in allowed_statuses do
        :ok
      else
        {:error, :invalid_status}
      end
    else
      {:error, :assistant_only}
    end
  end

  defp normalize_allowed_statuses(statuses) when is_list(statuses) do
    statuses
    |> Enum.map(&normalize_status/1)
    |> Enum.filter(&(&1 in [:generating, :error, :canceled, :done]))
    |> Enum.uniq()
  end

  defp normalize_allowed_statuses(_other), do: [:error, :canceled]

  defp normalize_status(value) when value in [:generating, :error, :canceled, :done], do: value
  defp normalize_status("generating"), do: :generating
  defp normalize_status("error"), do: :error
  defp normalize_status("canceled"), do: :canceled
  defp normalize_status("done"), do: :done
  defp normalize_status(_other), do: nil

  defp load_retry_step(message, opts) when is_map(message) and is_list(opts) do
    case Keyword.fetch(opts, :step_id) do
      {:ok, step_id} -> load_retry_step_by_id(message, step_id)
      :error -> load_last_retry_step(message)
    end
  end

  defp load_retry_step_by_id(message, step_id)
       when is_map(message) and is_integer(step_id) and step_id > 0 do
    step =
      message
      |> Map.get(:steps, [])
      |> Enum.find(fn
        %{id: id, sequence: sequence}
        when id == step_id and is_integer(sequence) and sequence > 0 ->
          true

        _other ->
          false
      end)

    case step do
      nil -> {:error, :step_not_found}
      step -> {:ok, step}
    end
  end

  defp load_retry_step_by_id(_message, _step_id), do: {:error, :step_not_found}

  defp load_last_retry_step(message) when is_map(message) do
    steps = Map.get(message, :steps) || []

    step =
      steps
      |> Enum.filter(fn
        %{sequence: sequence} when is_integer(sequence) and sequence > 0 -> true
        _other -> false
      end)
      |> Enum.max_by(fn step -> {Map.get(step, :sequence, 0), Map.get(step, :id, 0)} end, fn ->
        nil
      end)

    case step do
      nil -> {:error, :no_steps_to_retry}
      step -> {:ok, step}
    end
  end

  defp normalize_retry_request_payload(%{} = raw_request) do
    payload = stringify_keys(raw_request)

    if map_size(payload) > 0 do
      {:ok, payload}
    else
      {:error, :invalid_step_request}
    end
  end

  defp normalize_retry_request_payload(raw_request) when is_binary(raw_request) do
    case Jason.decode(raw_request) do
      {:ok, %{} = payload} -> normalize_retry_request_payload(payload)
      _other -> {:error, :invalid_step_request}
    end
  end

  defp normalize_retry_request_payload(_other), do: {:error, :invalid_step_request}

  defp stringify_keys(%{} = value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), stringify_keys(nested_value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp load_retry_chat(message) when is_map(message) do
    case Map.get(message, :chat) do
      %{} = chat -> {:ok, chat}
      _other -> {:error, :not_found}
    end
  end

  defp resolve_retry_configuration(message, chat, actor)
       when is_map(message) and is_map(chat) do
    config_id =
      cond do
        is_integer(Map.get(message, :llm_configuration_id)) ->
          Map.get(message, :llm_configuration_id)

        is_integer(Map.get(chat, :llm_configuration_id)) ->
          Map.get(chat, :llm_configuration_id)

        true ->
          nil
      end

    cond do
      is_map(Map.get(message, :llm_configuration)) ->
        {:ok, Map.get(message, :llm_configuration)}

      is_map(Map.get(chat, :llm_configuration)) ->
        {:ok, Map.get(chat, :llm_configuration)}

      is_integer(config_id) ->
        case Ash.get(LlmConfiguration, config_id, actor: actor, load: [:provider]) do
          {:ok, configuration} -> {:ok, configuration}
          {:error, _error} -> {:error, :configuration_not_found}
        end

      true ->
        {:ok, nil}
    end
  end

  @payload_reserved_keys [
    "model",
    "messages",
    "input",
    "stream",
    "store",
    "instructions",
    "tools",
    "include",
    "tool_choice"
  ]

  defp payload_model_name(payload, llm_configuration)
       when is_map(payload) do
    from_payload =
      payload
      |> Map.get("model")
      |> to_string()
      |> String.trim()

    if from_payload != "" do
      from_payload
    else
      case llm_configuration do
        %{} = cfg -> Map.get(cfg, :model_name)
        _other -> nil
      end
    end
  end

  defp payload_model_name(_payload, llm_configuration) do
    case llm_configuration do
      %{} = cfg -> Map.get(cfg, :model_name)
      _other -> nil
    end
  end

  defp payload_parameters(payload, llm_configuration)
       when is_map(payload) do
    parameters =
      payload
      |> Map.drop(@payload_reserved_keys)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    cond do
      map_size(parameters) > 0 ->
        parameters

      is_map(llm_configuration) and is_map(Map.get(llm_configuration, :parameters)) ->
        stringify_keys(Map.get(llm_configuration, :parameters))

      true ->
        %{}
    end
  end

  defp payload_parameters(_payload, llm_configuration) do
    if is_map(llm_configuration) and is_map(Map.get(llm_configuration, :parameters)) do
      stringify_keys(Map.get(llm_configuration, :parameters))
    else
      %{}
    end
  end

  defp payload_messages(payload) when is_map(payload) do
    messages = Map.get(payload, "messages")
    if is_list(messages), do: messages, else: []
  end

  defp payload_messages(_payload), do: []

  defp payload_instructions(payload) when is_map(payload) do
    payload
    |> Map.get("instructions")
    |> to_string()
  end

  defp payload_instructions(_payload), do: ""

  defp configuration_timeout_ms(%{} = llm_configuration) do
    timeout_seconds =
      case Map.get(llm_configuration, :timeout_seconds) do
        value when is_integer(value) and value > 0 -> value
        _other -> 300
      end

    timeout_seconds * 1000
  end

  defp configuration_timeout_ms(_other), do: nil

  defp configuration_context_length(%{} = llm_configuration) do
    case Map.get(llm_configuration, :context_length) do
      value when is_integer(value) and value > 0 -> value
      _other -> nil
    end
  end

  defp configuration_context_length(_other), do: nil

  defp maybe_disable_tools_for_retry(request_payload, tools_payload)
       when is_map(request_payload) and is_list(tools_payload) do
    tools = Map.get(request_payload, "tools")
    tool_choice = Map.get(request_payload, "tool_choice")

    has_tools? = is_list(tools) and tools != []
    has_tool_choice? = not is_nil(tool_choice)

    if has_tools? or has_tool_choice? do
      tools_payload
    else
      []
    end
  end

  defp maybe_disable_tools_for_retry(_request_payload, _tools_payload), do: []

  defp provider_type_for_configuration(%{provider: %{type: type}})
       when type in [:responses, :openrouter_chat_completion, :openai_compatible, :demo],
       do: type

  defp provider_type_for_configuration(%{provider: %{type: type}}) when is_atom(type), do: type
  defp provider_type_for_configuration(_other), do: :demo

  defp provider_type_for_chat(chat) do
    case Map.get(chat, :llm_configuration) do
      %{provider: %{type: type}} when type in [:responses, :openrouter_chat_completion, :demo] ->
        type

      _ ->
        nil
    end
  end

  defp max_tool_rounds_for_chat(chat) do
    case Map.get(chat, :bot) do
      %{max_tool_rounds: value} when is_integer(value) and value >= 0 -> value
      _ -> 20
    end
  end

  defp context_soft_limit_percent_for_chat(chat) do
    case Map.get(chat, :bot) do
      %{context_soft_limit_percent: value} when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp load_bot_blocks(bot_id, actor) when is_integer(bot_id) do
    BotKnowledgeBlock
    |> Ash.Query.filter(bot_id == ^bot_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load(:knowledge_block)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.knowledge_block)
    |> Enum.reject(&is_nil/1)
  end

  defp load_bot_blocks(_bot_id, _actor), do: []

  defp load_chat_blocks(chat_id, actor) when is_integer(chat_id) do
    ChatKnowledgeBlock
    |> Ash.Query.filter(chat_id == ^chat_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load(:knowledge_block)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.knowledge_block)
    |> Enum.reject(&is_nil/1)
  end

  defp load_chat_blocks(_chat_id, _actor), do: []

  defp load_configuration_blocks(configuration_id, actor) when is_integer(configuration_id) do
    LlmConfigurationKnowledgeBlock
    |> Ash.Query.filter(llm_configuration_id == ^configuration_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.select([:id, :selection, :sequence, :knowledge_block_id])
    |> Ash.Query.load(:knowledge_block)
    |> Ash.read!(actor: actor)
  end

  defp load_configuration_blocks(_configuration_id, _actor), do: []

  defp split_configuration_blocks(bindings) when is_list(bindings) do
    Enum.reduce(bindings, {[], []}, fn binding, {top, bottom} ->
      block = Map.get(binding, :knowledge_block)

      cond do
        is_nil(block) ->
          {top, bottom}

        Map.get(binding, :selection) == :top ->
          {[block | top], bottom}

        true ->
          {top, [block | bottom]}
      end
    end)
    |> then(fn {top, bottom} -> {Enum.reverse(top), Enum.reverse(bottom)} end)
  end

  defp split_configuration_blocks(_other), do: {[], []}

  defp load_user_blocks(%{id: owner_id} = actor) when is_integer(owner_id) do
    UserKnowledgeBlock
    |> Ash.Query.filter(owner_id == ^owner_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load(:knowledge_block)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.knowledge_block)
    |> Enum.reject(&is_nil/1)
  end

  defp load_user_blocks(_actor), do: []
end
