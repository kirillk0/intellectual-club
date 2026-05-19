defmodule IntellectualClubWeb.Bff.ChatsController do
  @moduledoc """
  Chat-oriented BFF endpoints for the SPA.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotCompatibleConfigurationTag
  alias IntellectualClub.Chat.Bookmarking
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.Continuation
  alias IntellectualClub.Chat.ListingStats
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Metrics, as: ChatMetrics
  alias IntellectualClub.Chat.Previews
  alias IntellectualClub.Chat.Search, as: ChatSearch
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Context, as: GenerationContext
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationTag
  alias IntellectualClub.Llm.LlmConfigurationTagBinding
  alias IntellectualClub.Sharing
  alias IntellectualClub.Tools.BindingResolver
  alias IntellectualClub.Tools.ChatToolBinding
  alias IntellectualClub.Tools.ToolInstance
  alias IntellectualClubWeb.Bff.ChatAttachments
  alias IntellectualClubWeb.Bff.ChatUploadPolicy
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Loads
  alias IntellectualClubWeb.Bff.Serializer

  require Ash.Query

  def index(conn, _params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, bot_filter} <- parse_bot_filter(conn.params) do
      preview_len = preview_len(conn.params)
      pagination = pagination_params(conn.params)

      page =
        Chat
        |> Ash.Query.filter(owner_id == ^actor.id)
        |> maybe_apply_chat_bot_filter(bot_filter)
        |> Ash.Query.sort(updated_at: :desc, id: :desc)
        |> Ash.Query.load([
          :bot,
          :last_message,
          :active_root_message_id,
          :can_edit,
          :shared_incoming,
          :shared_outgoing,
          llm_configuration: [:provider]
        ])
        |> Ash.Query.page(
          limit: pagination.per_page,
          offset: (pagination.page - 1) * pagination.per_page,
          count: true
        )
        |> Ash.read!(actor: actor)

      chats = Map.get(page, :results, [])

      message_count_by_chat =
        Threads.active_branch_counts_by_chat(Enum.map(chats, & &1.id), actor)

      first_message_previews = load_active_root_message_previews(chats, preview_len, actor)
      sidebar_stats = ListingStats.sidebar(actor)

      payload =
        Enum.map(chats, fn chat ->
          activity_at = chat_activity_at(chat)

          {first_message_preview, first_message_role} =
            Map.get(first_message_previews, chat.id, {nil, nil})

          Serializer.chat_summary(chat, activity_at: activity_at)
          |> Map.put(:message_count, Map.get(message_count_by_chat, chat.id, 0))
          |> Map.put(:first_message_preview, first_message_preview)
          |> Map.put(:first_message_role, first_message_role)
        end)

      json(conn, %{
        chats: payload,
        page: %{
          number: pagination.page,
          per_page: pagination.per_page,
          total: Map.get(page, :count, length(payload)),
          has_next: Map.get(page, :more?, false)
        },
        stats: Serializer.chat_list_stats(sidebar_stats)
      })
    else
      {:error, error_message} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: error_message})
    end
  end

  def search_messages(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      term = params |> Map.get("q", "") |> to_string()

      json(conn, ChatSearch.search_messages_in_chat(chat_id, term, actor))
    end
  end

  def search(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      term = params |> Map.get("q", "") |> to_string()
      pagination = pagination_params(params)

      with {:ok, bot_filter} <- parse_bot_filter(params) do
        payload =
          term
          |> ChatSearch.search_chats(actor,
            bot_filter: bot_filter,
            limit: pagination.per_page
          )
          |> Enum.map(fn entry ->
            chat = entry.chat
            activity_at = chat_activity_at(chat)

            Serializer.chat_summary(chat, activity_at: activity_at)
            |> Map.put(:message_count, entry.message_count)
            |> Map.put(:match_type, match_type_to_string(entry.match_type))
            |> Map.put(:snippet, entry.snippet)
            |> Map.put(:message_id, entry.message_id)
            |> Map.put(:message_role, entry.message_role)
          end)

        json(conn, %{chats: payload})
      else
        {:error, error_message} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: error_message})
      end
    end
  end

  def create(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_params = %{
        title: Map.get(params, "title", "Untitled chat"),
        note: Map.get(params, "note", ""),
        bot_id: Helpers.parse_optional_integer(Map.get(params, "bot_id")),
        llm_configuration_id:
          Helpers.parse_optional_integer(Map.get(params, "llm_configuration_id")),
        variables: Serializer.map_from_variable_entries(Map.get(params, "variables", []))
      }

      chat_params = maybe_apply_default_llm_configuration(chat_params, params, actor)

      chat =
        Chat
        |> Ash.Changeset.for_create(:create, chat_params, actor: actor)
        |> Ash.create!()

      json(conn, %{chat: Serializer.chat_detail(chat)})
    end
  end

  defp parse_bot_filter(params) when is_map(params) do
    raw =
      params
      |> Map.get("bot")
      |> case do
        nil -> ""
        other -> to_string(other)
      end
      |> String.trim()

    cond do
      raw == "" ->
        {:ok, nil}

      raw == "none" ->
        {:ok, :none}

      true ->
        case Integer.parse(raw) do
          {value, ""} when value > 0 -> {:ok, value}
          _ -> {:error, "bot must be an integer or none"}
        end
    end
  end

  defp maybe_apply_chat_bot_filter(query, nil), do: query
  defp maybe_apply_chat_bot_filter(query, :none), do: Ash.Query.filter(query, is_nil(bot_id))

  defp maybe_apply_chat_bot_filter(query, bot_id) when is_integer(bot_id) do
    Ash.Query.filter(query, bot_id == ^bot_id)
  end

  defp maybe_apply_chat_bot_filter(query, _other), do: query

  defp pagination_params(params) when is_map(params) do
    %{
      page: parse_positive_integer(Map.get(params, "page"), 1),
      per_page: parse_positive_integer(Map.get(params, "per_page"), 20, 100)
    }
  end

  defp parse_positive_integer(nil, default), do: default
  defp parse_positive_integer("", default), do: default
  defp parse_positive_integer(value, default), do: parse_positive_integer(value, default, nil)

  defp parse_positive_integer(value, default, max_value) do
    parsed =
      case Integer.parse(to_string(value)) do
        {number, ""} when number > 0 -> number
        _ -> default
      end

    if is_integer(max_value) and max_value > 0 do
      min(parsed, max_value)
    else
      parsed
    end
  end

  defp match_type_to_string(:meta), do: "meta"
  defp match_type_to_string(:active_message), do: "active_message"
  defp match_type_to_string(:inactive_message), do: "inactive_message"
  defp match_type_to_string(other) when is_binary(other), do: other
  defp match_type_to_string(other) when is_atom(other), do: Atom.to_string(other)
  defp match_type_to_string(_other), do: nil

  defp maybe_apply_default_llm_configuration(chat_params, params, actor) do
    if Map.has_key?(params, "llm_configuration_id") do
      chat_params
    else
      case default_llm_configuration_id(actor, Map.get(chat_params, :bot_id)) do
        nil -> chat_params
        llm_configuration_id -> Map.put(chat_params, :llm_configuration_id, llm_configuration_id)
      end
    end
  end

  defp default_llm_configuration_id(actor, bot_id) do
    available_configurations = available_llm_configurations_for_bot(actor, bot_id)

    latest_chat_llm_configuration_id(
      actor,
      bot_id,
      Enum.map(available_configurations, & &1.id)
    ) ||
      bot_default_llm_configuration_id(actor, bot_id) ||
      first_available_llm_configuration_id(available_configurations)
  end

  defp first_available_llm_configuration_id([
         %LlmConfiguration{id: llm_configuration_id} | _rest
       ]),
       do: llm_configuration_id

  defp first_available_llm_configuration_id(_available_configurations), do: nil

  defp bot_default_llm_configuration_id(_actor, bot_id) when not is_integer(bot_id), do: nil

  defp bot_default_llm_configuration_id(actor, bot_id) do
    Bot
    |> Ash.Query.filter(id == ^bot_id)
    |> Ash.Query.select([:id, :default_llm_configuration_id])
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: actor)
    |> case do
      [%Bot{default_llm_configuration_id: llm_configuration_id}]
      when is_integer(llm_configuration_id) ->
        if accessible_llm_configuration?(actor, llm_configuration_id) do
          llm_configuration_id
        end

      _other ->
        nil
    end
  end

  defp accessible_llm_configuration?(actor, llm_configuration_id)
       when is_integer(llm_configuration_id) do
    case Ash.get(LlmConfiguration, llm_configuration_id, actor: actor) do
      {:ok, %LlmConfiguration{}} -> true
      _other -> false
    end
  end

  defp accessible_llm_configuration?(_actor, _llm_configuration_id), do: false

  defp available_llm_configurations_for_bot(actor, bot_id) do
    enabled_configurations =
      actor
      |> load_llm_configurations()
      |> Enum.filter(&(&1.enabled == true))

    case compatible_llm_configuration_ids_for_bot(actor, bot_id) do
      :all ->
        enabled_configurations

      compatible_ids ->
        Enum.filter(enabled_configurations, &(&1.id in compatible_ids))
    end
  end

  defp latest_chat_llm_configuration_id(_actor, _bot_id, []), do: nil

  defp latest_chat_llm_configuration_id(actor, bot_id, available_ids) do
    Chat
    |> maybe_apply_default_llm_configuration_chat_filter(bot_id)
    |> Ash.Query.filter(owner_id == ^actor.id)
    |> Ash.Query.filter(
      not is_nil(llm_configuration_id) and llm_configuration_id in ^available_ids
    )
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: actor)
    |> case do
      [%Chat{llm_configuration_id: llm_configuration_id}] -> llm_configuration_id
      _ -> nil
    end
  end

  defp maybe_adjust_llm_configuration_for_bot_change(patch, _chat, _actor)
       when not is_map(patch) do
    patch
  end

  defp maybe_adjust_llm_configuration_for_bot_change(patch, chat, actor) do
    cond do
      Map.has_key?(patch, :llm_configuration_id) ->
        patch

      not Map.has_key?(patch, :bot_id) ->
        patch

      not is_integer(chat.llm_configuration_id) ->
        patch

      configuration_compatible_with_bot?(
        actor,
        Map.get(patch, :bot_id),
        chat.llm_configuration_id
      ) ->
        patch

      true ->
        Map.put(
          patch,
          :llm_configuration_id,
          default_llm_configuration_id(actor, Map.get(patch, :bot_id))
        )
    end
  end

  defp maybe_apply_default_llm_configuration_chat_filter(query, bot_id) when is_integer(bot_id) do
    Ash.Query.filter(query, bot_id == ^bot_id)
  end

  defp maybe_apply_default_llm_configuration_chat_filter(query, nil) do
    Ash.Query.filter(query, is_nil(bot_id))
  end

  defp maybe_apply_default_llm_configuration_chat_filter(query, _other), do: query

  defp configuration_compatible_with_bot?(_actor, bot_id, _llm_configuration_id)
       when not is_integer(bot_id) do
    true
  end

  defp configuration_compatible_with_bot?(_actor, _bot_id, llm_configuration_id)
       when not is_integer(llm_configuration_id) do
    true
  end

  defp configuration_compatible_with_bot?(actor, bot_id, llm_configuration_id) do
    case compatible_llm_configuration_ids_for_bot(actor, bot_id) do
      :all -> true
      compatible_ids -> llm_configuration_id in compatible_ids
    end
  end

  defp compatible_llm_configuration_ids_for_bot(_actor, bot_id) when not is_integer(bot_id),
    do: :all

  defp compatible_llm_configuration_ids_for_bot(actor, bot_id) do
    %{tag_ids: tag_ids, tag_names: tag_names} =
      compatible_configuration_tag_match_for_bot(actor, bot_id)

    case {tag_ids, tag_names} do
      {[], []} ->
        :all

      {_tag_ids, _tag_names} ->
        matching_tag_ids = matching_configuration_tag_ids(actor, tag_ids, tag_names)

        LlmConfigurationTagBinding
        |> Ash.Query.filter(llm_configuration_tag_id in ^matching_tag_ids)
        |> Ash.read!(actor: actor)
        |> Enum.map(& &1.llm_configuration_id)
        |> Enum.uniq()
    end
  end

  defp compatible_configuration_tag_match_for_bot(actor, bot_id) do
    BotCompatibleConfigurationTag
    |> Ash.Query.filter(bot_id == ^bot_id)
    |> Ash.Query.load([:tag_name], strict?: true)
    |> Ash.read!(actor: actor)
    |> Enum.reduce(%{tag_ids: [], tag_names: []}, fn binding, acc ->
      tag_ids =
        case binding.llm_configuration_tag_id do
          tag_id when is_integer(tag_id) -> [tag_id | acc.tag_ids]
          _other -> acc.tag_ids
        end

      tag_names =
        case normalize_configuration_tag_name(Map.get(binding, :tag_name)) do
          nil -> acc.tag_names
          tag_name -> [tag_name | acc.tag_names]
        end

      %{tag_ids: tag_ids, tag_names: tag_names}
    end)
    |> then(fn %{tag_ids: tag_ids, tag_names: tag_names} ->
      %{
        tag_ids: tag_ids |> Enum.uniq() |> Enum.sort(),
        tag_names: tag_names |> Enum.uniq() |> Enum.sort()
      }
    end)
  end

  defp matching_configuration_tag_ids(actor, tag_ids, tag_names) do
    matching_tag_ids =
      LlmConfigurationTag
      |> Ash.Query.select([:id, :name])
      |> Ash.read!(actor: actor)
      |> Enum.filter(fn tag ->
        tag.id in tag_ids or normalize_configuration_tag_name(tag.name) in tag_names
      end)
      |> Enum.map(& &1.id)

    (tag_ids ++ matching_tag_ids)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_configuration_tag_name(name) when is_binary(name) do
    case name |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_configuration_tag_name(_other), do: nil

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)

      allowed_fields =
        ~w(title note bot_id llm_configuration_id variables knowledge_block_bindings tool_bindings)

      with {:ok, chat} <- fetch_owned_chat(chat_id, actor) do
        patch =
          params
          |> Map.take(allowed_fields)
          |> normalize_chat_patch()
          |> maybe_adjust_llm_configuration_for_bot_change(chat, actor)

        chat =
          chat
          |> Ash.Changeset.for_update(:update, patch, actor: actor)
          |> Ash.update!()

        json(conn, %{chat: Serializer.chat_detail(chat)})
      else
        {:error, error} -> render_access_error(conn, error)
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)

      with {:ok, chat} <- fetch_owned_chat(chat_id, actor) do
        case Ash.destroy(chat, actor: actor) do
          :ok ->
            json(conn, %{status: "ok"})

          {:ok, _chat} ->
            json(conn, %{status: "ok"})

          {:error, %Ash.Error.Forbidden{} = error} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Forbidden: #{Exception.message(error)}"})

          {:error, %Ash.Error.Invalid{} = error} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Invalid request: #{Exception.message(error)}"})

          {:error, error} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to delete chat: #{inspect(error)}"})
        end
      else
        {:error, error} -> render_access_error(conn, error)
      end
    end
  end

  def state(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- parse_resource_id(id),
         {:ok, %Chat{} = chat} <- fetch_readable_chat(chat_id, actor) do
      {messages, branch_meta_by_id} = load_branch(chat, actor)

      chat_blocks = load_chat_blocks(chat_id, actor)
      chat_tool_bindings = load_chat_tool_bindings(chat_id, actor)
      tool_resolution = BindingResolver.resolve_for_chat(chat, actor)

      prompt_context =
        build_prompt_context_payload(chat, actor,
          history: messages,
          tool_resolution: tool_resolution
        )

      bots = load_bots(actor)
      llm_configurations = load_llm_configurations(actor)
      knowledge_blocks = load_knowledge_blocks(actor)
      tool_instances = load_editable_tool_instances(actor)

      generating_message_id =
        messages
        |> Enum.find_value(fn message ->
          if message.status == :generating, do: message.id, else: nil
        end)

      json(conn, %{
        chat: Serializer.chat_detail(chat),
        branch: serialize_branch(messages, branch_meta_by_id, actor),
        chat_blocks: Enum.map(chat_blocks, &Serializer.chat_block_binding/1),
        chat_tool_bindings: Enum.map(chat_tool_bindings, &Serializer.chat_tool_binding/1),
        prompt_sources: prompt_context.prompt_sources,
        prompt_blocks: prompt_context.prompt_blocks,
        compiled_prompt_text: prompt_context.compiled_prompt_text,
        counters: prompt_context.counters,
        active_tool_instances:
          Enum.map(tool_resolution.active_tool_instances, &Serializer.tool_instance_option/1),
        active_tool_bindings:
          Enum.map(tool_resolution.effective_tool_bindings, &Serializer.active_tool_binding/1),
        missing_required_per_user_tool_aliases: tool_resolution.missing_aliases,
        options: %{
          bots: Enum.map(bots, &Serializer.bot_option/1),
          llm_configurations: Enum.map(llm_configurations, &Serializer.configuration_option/1),
          knowledge_blocks: Enum.map(knowledge_blocks, &Serializer.knowledge_block_option/1),
          tool_instances: Enum.map(tool_instances, &Serializer.tool_instance_option/1)
        },
        active_generation_message_id: generating_message_id
      })
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:ok, nil} ->
        render_access_error(conn, :not_found)

      {:error, error} ->
        render_access_error(conn, error)
    end
  end

  def shares(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- parse_resource_id(id),
         {:ok, state} <- Sharing.get_chat_share_state(chat_id, actor) do
      json(conn, state)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_access_error(conn, error)
    end
  end

  def update_shares(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- parse_resource_id(id),
         {:ok, group_ids} <- parse_group_ids(params),
         {:ok, state} <- Sharing.replace_chat_share_state(chat_id, group_ids, actor) do
      json(conn, state)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_access_error(conn, error)
    end
  end

  def continue_conversation(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, chat_id} <- parse_resource_id(id),
         {:ok, chat} <- Continuation.continue_chat(chat_id, actor) do
      json(conn, %{chat: Serializer.chat_detail(chat)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_access_error(conn, error)
    end
  end

  def prompt_context(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      chat = Ash.get!(Chat, chat_id, actor: actor)
      history = Threads.active_branch(chat, actor)
      tool_resolution = BindingResolver.resolve_for_chat(chat, actor)

      json(
        conn,
        build_prompt_context_payload(chat, actor,
          history: history,
          tool_resolution: tool_resolution
        )
      )
    end
  end

  def send(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      content = params |> Map.get("content", "") |> to_string()
      explicit_parent? = Map.has_key?(params, "parent_id")
      parent_id = Helpers.parse_optional_integer(Map.get(params, "parent_id"))

      with {:ok, _chat} <- fetch_owned_chat(chat_id, actor),
           upload_policy = ChatUploadPolicy.load_for_chat(chat_id, actor),
           {:ok, prepared_uploads} <- ChatAttachments.parse_prepared_uploads(params),
           {:ok, :ok} <-
             create_user_message_with_prepared_attachments(
               chat_id,
               actor,
               upload_policy,
               prepared_uploads,
               content,
               parent_id,
               explicit_parent?
             ),
           {:ok, context} <- GenerationSupervisor.start_generation(chat_id, actor: actor) do
        {messages, branch_meta_by_id} = load_branch(chat_id, actor)

        json(conn, %{
          branch: serialize_branch(messages, branch_meta_by_id, actor),
          generation: %{message_id: context.message_id}
        })
      else
        {:error, :forbidden} ->
          render_access_error(conn, :forbidden)

        {:error, :not_found} ->
          render_access_error(conn, :not_found)

        {:error, {:user_message, error}} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to create user message: #{inspect(error)}"})

        {:error, error_message} when is_binary(error_message) ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: error_message})

        other ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to start generation: #{inspect(other)}"})
      end
    end
  end

  defp create_user_message_with_prepared_attachments(
         chat_id,
         actor,
         upload_policy,
         prepared_uploads,
         content,
         parent_id,
         explicit_parent?
       ) do
    ChatAttachments.with_prepared_file_ids(
      chat_id,
      actor,
      upload_policy,
      prepared_uploads,
      fn file_ids ->
        text_contents =
          case to_string(content || "") do
            "" -> []
            text -> [%{kind: :text, content_text: text}]
          end

        media_contents = Enum.map(file_ids, &%{kind: :media, file_id: &1})

        maybe_create_user_message(
          chat_id,
          text_contents ++ media_contents,
          parent_id,
          explicit_parent?,
          actor
        )
        |> case do
          :ok -> {:ok, :ok}
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  defp maybe_create_user_message(chat_id, contents, parent_id, explicit_parent?, actor) do
    if contents == [] do
      :ok
    else
      create_result =
        if explicit_parent? do
          Threads.add_message(chat_id, :user, "",
            actor: actor,
            parent_id: parent_id,
            contents: contents
          )
        else
          Threads.add_message_to_end(chat_id, :user, "",
            actor: actor,
            contents: contents
          )
        end

      with {:ok, _message} <- create_result do
        :ok
      else
        {:error, error} ->
          {:error, {:user_message, error}}
      end
    end
  end

  def generate(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      parent_id = Helpers.parse_optional_integer(Map.get(params, "parent_id"))
      generation_opts = maybe_put_parent_id([actor: actor], parent_id)

      with {:ok, _chat} <- fetch_owned_chat(chat_id, actor) do
        case GenerationSupervisor.start_generation(chat_id, generation_opts) do
          {:ok, context} ->
            {messages, branch_meta_by_id} = load_branch(chat_id, actor)

            json(conn, %{
              branch: serialize_branch(messages, branch_meta_by_id, actor),
              generation: %{message_id: context.message_id}
            })

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to start generation: #{inspect(reason)}"})
        end
      else
        {:error, error} -> render_access_error(conn, error)
      end
    end
  end

  defp maybe_put_parent_id(opts, parent_id) when is_integer(parent_id) do
    Keyword.put(opts, :parent_id, parent_id)
  end

  defp maybe_put_parent_id(opts, _parent_id), do: opts

  def switch_branch(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      message_id = Helpers.parse_optional_integer(Map.get(params, "message_id"))
      direction = Map.get(params, "direction")
      target_id = Helpers.parse_optional_integer(Map.get(params, "target_id"))

      opts =
        [
          actor: actor
        ]
        |> maybe_put_switch_direction(direction)
        |> maybe_put_switch_target(target_id)

      with {:ok, _chat} <- fetch_owned_chat(chat_id, actor),
           message_id when is_integer(message_id) <- message_id,
           {:ok, _meta} <- Threads.switch_branch(chat_id, message_id, opts) do
        {messages, branch_meta_by_id} = load_branch(chat_id, actor)

        json(conn, %{
          branch: serialize_branch(messages, branch_meta_by_id, actor)
        })
      else
        nil ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "message_id is required"})

        {:error, :forbidden} ->
          render_access_error(conn, :forbidden)

        {:error, :not_found} ->
          render_access_error(conn, :not_found)

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to switch branch: #{inspect(reason)}"})
      end
    end
  end

  def activate_branch(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      message_id = Helpers.parse_optional_integer(Map.get(params, "message_id"))

      with {:ok, _chat} <- fetch_owned_chat(chat_id, actor),
           message_id when is_integer(message_id) <- message_id,
           {:ok, _meta} <- Threads.activate_branch(chat_id, message_id, actor) do
        {messages, branch_meta_by_id} = load_branch(chat_id, actor)

        json(conn, %{
          branch: serialize_branch(messages, branch_meta_by_id, actor)
        })
      else
        nil ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "message_id is required"})

        {:error, :forbidden} ->
          render_access_error(conn, :forbidden)

        {:error, :not_found} ->
          render_access_error(conn, :not_found)

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to activate branch: #{inspect(reason)}"})
      end
    end
  end

  defp normalize_chat_patch(params) do
    params
    |> Enum.reduce(%{}, fn
      {"bot_id", value}, acc ->
        Map.put(acc, :bot_id, Helpers.parse_optional_integer(value))

      {"llm_configuration_id", value}, acc ->
        Map.put(acc, :llm_configuration_id, Helpers.parse_optional_integer(value))

      {"variables", value}, acc ->
        Map.put(acc, :variables, Serializer.map_from_variable_entries(value))

      {"knowledge_block_bindings", value}, acc ->
        bindings =
          value
          |> List.wrap()
          |> Enum.map(fn
            %{} = item ->
              id = Helpers.parse_optional_integer(Map.get(item, "id"))

              knowledge_block_id =
                Helpers.parse_optional_integer(
                  Map.get(item, "knowledge_block_id") || Map.get(item, "block")
                )

              enabled =
                case Map.get(item, "enabled", true) do
                  false -> false
                  "false" -> false
                  _ -> true
                end

              cond do
                not is_integer(knowledge_block_id) ->
                  nil

                is_integer(id) and id > 0 ->
                  %{id: id, knowledge_block_id: knowledge_block_id, enabled: enabled}

                true ->
                  %{knowledge_block_id: knowledge_block_id, enabled: enabled}
              end

            _other ->
              nil
          end)
          |> Enum.reject(&is_nil/1)

        Map.put(acc, :knowledge_block_bindings, bindings)

      {"tool_bindings", value}, acc ->
        bindings =
          value
          |> List.wrap()
          |> Enum.with_index()
          |> Enum.map(fn
            {%{} = item, index} ->
              id = Helpers.parse_optional_integer(Map.get(item, "id"))
              tool_instance_id = Helpers.parse_optional_integer(Map.get(item, "tool_instance_id"))

              enabled =
                case Map.get(item, "enabled", true) do
                  false -> false
                  "false" -> false
                  _ -> true
                end

              cond do
                not is_integer(tool_instance_id) ->
                  nil

                is_integer(id) and id > 0 ->
                  %{
                    id: id,
                    tool_instance_id: tool_instance_id,
                    enabled: enabled,
                    sequence: index
                  }

                true ->
                  %{
                    tool_instance_id: tool_instance_id,
                    enabled: enabled,
                    sequence: index
                  }
              end

            _other ->
              nil
          end)
          |> Enum.reject(&is_nil/1)

        Map.put(acc, :tool_bindings, bindings)

      {key, value}, acc when key in ["title", "note"] ->
        Map.put(acc, String.to_existing_atom(key), value)

      _other, acc ->
        acc
    end)
  end

  defp chat_activity_at(chat) do
    case Map.get(chat, :last_message) do
      %{created_at: %DateTime{} = created_at} ->
        created_at

      %{created_at: %NaiveDateTime{} = created_at} ->
        created_at

      _ ->
        chat.updated_at || chat.created_at
    end
  end

  defp preview_len(params) when is_map(params) do
    default = 200

    case Map.get(params, "preview_len") do
      nil ->
        default

      "" ->
        default

      raw ->
        with {value, ""} <- Integer.parse(to_string(raw)),
             value when value > 0 <- value do
          min(value, 500)
        else
          _ -> default
        end
    end
  end

  defp load_active_root_message_previews(chats, preview_len, actor)
       when is_list(chats) and is_integer(preview_len) do
    root_message_ids_by_chat =
      chats
      |> Enum.reduce(%{}, fn chat, acc ->
        case Map.get(chat, :active_root_message_id) do
          message_id when is_integer(message_id) ->
            Map.put(acc, chat.id, message_id)

          _ ->
            acc
        end
      end)

    message_ids = root_message_ids_by_chat |> Map.values() |> Enum.uniq()

    messages_by_id =
      if message_ids == [] do
        %{}
      else
        ChatMessage
        |> Ash.Query.filter(id in ^message_ids)
        |> Ash.Query.load(Loads.message_tree(), strict?: true)
        |> Ash.read!(actor: actor)
        |> Map.new(fn message -> {message.id, message} end)
      end

    Enum.reduce(root_message_ids_by_chat, %{}, fn {chat_id, message_id}, acc ->
      case Map.get(messages_by_id, message_id) do
        nil ->
          acc

        message ->
          Map.put(acc, chat_id, Previews.message_preview(message, preview_len))
      end
    end)
  end

  defp load_branch(chat_or_id, actor) do
    {messages, branch_meta} =
      Threads.active_branch_with_meta(chat_or_id, actor,
        load: Loads.message_tree(),
        strict?: true
      )

    branch_meta_by_id = Map.new(branch_meta, fn node -> {node.id, node} end)
    {messages, branch_meta_by_id}
  end

  defp serialize_branch(messages, branch_meta_by_id, actor) do
    bookmarked_message_ids =
      messages
      |> Enum.map(& &1.id)
      |> Bookmarking.bookmarked_message_id_set(actor)

    Enum.map(messages, &Serializer.branch_message(&1, branch_meta_by_id, bookmarked_message_ids))
  end

  defp load_chat_blocks(chat_id, actor) do
    ChatKnowledgeBlock
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.select([:id, :chat_id, :knowledge_block_id, :enabled, :sequence])
    |> Ash.Query.load(Loads.prompt_source_binding(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_chat_tool_bindings(chat_id, actor) do
    ChatToolBinding
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load([tool_instance: [:name, :alias, :type, :outlet_online, :can_edit]],
      strict?: true
    )
    |> Ash.read!(actor: actor)
  end

  defp build_prompt_context_payload(chat, actor, opts) do
    history =
      Keyword.get_lazy(opts, :history, fn ->
        Threads.active_branch(chat, actor)
      end)

    snapshot =
      GenerationContext.prompt_snapshot!(chat,
        actor: actor,
        tool_resolution:
          Keyword.get_lazy(opts, :tool_resolution, fn ->
            BindingResolver.resolve_for_chat(chat, actor)
          end)
      )

    %{
      prompt_sources: serialize_prompt_sources(snapshot.prompt_sources),
      prompt_blocks: serialize_prompt_blocks(snapshot.prompt_blocks),
      compiled_prompt_text: snapshot.system_prompt,
      counters:
        ChatMetrics.counters_from_history(chat, history, actor,
          prompt_sources: snapshot.prompt_sources
        )
    }
  end

  defp serialize_prompt_sources(prompt_sources) when is_map(prompt_sources) do
    %{
      bot: Enum.map(Map.get(prompt_sources, :bot, []), &prompt_binding/1),
      chat: Enum.map(Map.get(prompt_sources, :chat, []), &prompt_binding/1),
      configuration: Enum.map(Map.get(prompt_sources, :configuration, []), &prompt_binding/1),
      user: Enum.map(Map.get(prompt_sources, :user, []), &prompt_binding/1)
    }
  end

  defp prompt_binding(binding) do
    block = Map.get(binding, :knowledge_block)

    %{
      id: binding.id,
      enabled: binding.enabled,
      selection: binding_selection(binding),
      sequence: binding.sequence,
      knowledge_block: if(is_map(block), do: Serializer.knowledge_block_option(block), else: nil)
    }
  end

  defp serialize_prompt_blocks(prompt_blocks) when is_list(prompt_blocks) do
    Enum.map(prompt_blocks, &prompt_block/1)
  end

  defp serialize_prompt_blocks(_prompt_blocks), do: []

  defp prompt_block(%{} = entry) do
    block = Map.get(entry, :knowledge_block)

    %{
      id: Map.get(entry, :id),
      source: prompt_block_source(Map.get(entry, :source)),
      selection: prompt_block_selection(Map.get(entry, :selection)),
      sequence: Map.get(entry, :sequence),
      prompt_order: Map.get(entry, :prompt_order),
      knowledge_block: if(is_map(block), do: Serializer.knowledge_block_option(block), else: nil)
    }
  end

  defp prompt_block_source(:bot), do: "bot"
  defp prompt_block_source(:chat), do: "chat"
  defp prompt_block_source(:config), do: "config"
  defp prompt_block_source(:user), do: "user"
  defp prompt_block_source(source) when is_binary(source), do: source
  defp prompt_block_source(_source), do: nil

  defp prompt_block_selection(:top), do: "top"
  defp prompt_block_selection(:bottom), do: "bottom"
  defp prompt_block_selection(value) when is_binary(value), do: value
  defp prompt_block_selection(_value), do: nil

  defp binding_selection(binding) when is_map(binding) do
    case Map.get(binding, :selection) do
      :top -> :top
      "top" -> :top
      _ -> :bottom
    end
  end

  defp load_llm_configurations(actor) do
    LlmConfiguration
    |> Ash.Query.sort(model_name: :asc, updated_at: :desc)
    |> Ash.Query.select(Loads.llm_configuration_option_select())
    |> Ash.Query.load(Loads.llm_configuration_option_load(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_bots(actor) do
    Bot
    |> Ash.Query.sort(name: :asc, updated_at: :desc)
    |> Ash.Query.select(Loads.bot_option_select())
    |> Ash.Query.load(Loads.bot_option_load(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_knowledge_blocks(actor) do
    KnowledgeBlock
    |> Ash.Query.sort(name: :asc, updated_at: :desc)
    |> Ash.Query.select(Loads.knowledge_block_option_select())
    |> Ash.Query.load(Loads.knowledge_block_option_load(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_editable_tool_instances(%{id: actor_id} = actor) when is_integer(actor_id) do
    ToolInstance
    |> Ash.Query.filter(owner_id == ^actor_id)
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.Query.load([:outlet_online, :can_edit], strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_editable_tool_instances(_actor), do: []

  defp maybe_put_switch_direction(opts, direction) do
    case direction do
      "prev" -> Keyword.put(opts, :direction, :prev)
      "next" -> Keyword.put(opts, :direction, :next)
      _ -> opts
    end
  end

  defp maybe_put_switch_target(opts, target_id) when is_integer(target_id),
    do: Keyword.put(opts, :target_id, target_id)

  defp maybe_put_switch_target(opts, _target_id), do: opts

  defp parse_resource_id(id) do
    case Helpers.parse_optional_integer(id) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, :not_found}
    end
  end

  defp parse_group_ids(params) do
    case Map.get(params, "group_ids", []) do
      ids when is_list(ids) ->
        if Enum.all?(ids, &valid_integer_like?/1) do
          {:ok, Helpers.parse_integer_list(ids)}
        else
          {:error, {:validation, "group_ids must contain integers."}}
        end

      _other ->
        {:error, {:validation, "group_ids must be a list."}}
    end
  end

  defp valid_integer_like?(value) when is_integer(value), do: true

  defp valid_integer_like?(value) when is_binary(value) do
    match?({number, ""} when number > 0, Integer.parse(value))
  end

  defp valid_integer_like?(_value), do: false

  defp fetch_owned_chat(chat_id, actor) do
    case Ash.get(Chat, chat_id, actor: actor) do
      {:ok, %Chat{owner_id: owner_id} = chat} when owner_id == actor.id -> {:ok, chat}
      {:ok, %Chat{}} -> {:error, :forbidden}
      {:ok, nil} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_readable_chat(chat_id, actor) do
    Chat
    |> Ash.Query.filter(id == ^chat_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.load([:can_edit, :shared_incoming, :shared_outgoing], strict?: true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = chat]} -> {:ok, chat}
      {:ok, []} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  defp render_access_error(conn, {:validation, message}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end

  defp render_access_error(conn, :forbidden) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Forbidden"})
  end

  defp render_access_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found"})
  end

  defp render_access_error(conn, %Ash.Error.Forbidden{}) do
    render_access_error(conn, :forbidden)
  end

  defp render_access_error(conn, %Ash.Error.Query.NotFound{}) do
    render_access_error(conn, :not_found)
  end

  defp render_access_error(conn, %Ash.Error.Invalid{} = error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Exception.message(error)})
  end

  defp render_access_error(conn, error) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: Exception.message(error)})
  end
end
