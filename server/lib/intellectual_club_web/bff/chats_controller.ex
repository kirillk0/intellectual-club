defmodule IntellectualClubWeb.Bff.ChatsController do
  @moduledoc """
  Chat-oriented BFF endpoints for the SPA.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Accounts.UserKnowledgeBlock
  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotCompatibleConfigurationTag
  alias IntellectualClub.Bots.BotKnowledgeBlock
  alias IntellectualClub.Chat.Bookmarking
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ListingStats
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Metrics, as: ChatMetrics
  alias IntellectualClub.Chat.Previews
  alias IntellectualClub.Chat.Search, as: ChatSearch
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.SystemPrompt
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Llm.LlmConfigurationTagBinding
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
        |> maybe_apply_chat_bot_filter(bot_filter)
        |> Ash.Query.sort(updated_at: :desc, id: :desc)
        |> Ash.Query.load([
          :bot,
          :last_message,
          :message_count,
          :active_root_message_id,
          llm_configuration: [:provider]
        ])
        |> Ash.Query.page(
          limit: pagination.per_page,
          offset: (pagination.page - 1) * pagination.per_page,
          count: true
        )
        |> Ash.read!(actor: actor)

      chats = Map.get(page, :results, [])
      first_message_previews = load_active_root_message_previews(chats, preview_len, actor)
      sidebar_stats = ListingStats.sidebar(actor)

      payload =
        Enum.map(chats, fn chat ->
          activity_at = chat_activity_at(chat)

          {first_message_preview, first_message_role} =
            Map.get(first_message_previews, chat.id, {nil, nil})

          Serializer.chat_summary(chat, activity_at: activity_at)
          |> Map.put(:message_count, chat_message_count(chat))
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

    case {
      latest_chat_llm_configuration_id(
        actor,
        bot_id,
        Enum.map(available_configurations, & &1.id)
      ),
      available_configurations
    } do
      {llm_configuration_id, _available_configurations} when is_integer(llm_configuration_id) ->
        llm_configuration_id

      {nil, [%LlmConfiguration{id: llm_configuration_id} | _rest]} ->
        llm_configuration_id

      _ ->
        nil
    end
  end

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
    tag_ids = compatible_configuration_tag_ids_for_bot(actor, bot_id)

    case tag_ids do
      [] ->
        :all

      _tag_ids ->
        LlmConfigurationTagBinding
        |> Ash.Query.filter(llm_configuration_tag_id in ^tag_ids)
        |> Ash.read!(actor: actor)
        |> Enum.map(& &1.llm_configuration_id)
        |> Enum.uniq()
    end
  end

  defp compatible_configuration_tag_ids_for_bot(actor, bot_id) do
    BotCompatibleConfigurationTag
    |> Ash.Query.filter(bot_id == ^bot_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.llm_configuration_tag_id)
    |> Enum.uniq()
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      chat = Ash.get!(Chat, chat_id, actor: actor)

      allowed_fields =
        ~w(title note bot_id llm_configuration_id variables knowledge_block_bindings tool_bindings)

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
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      chat = Ash.get!(Chat, chat_id, actor: actor)

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
    end
  end

  def state(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)

      chat = Ash.get!(Chat, chat_id, actor: actor)

      {messages, branch_meta_by_id} = load_branch(chat, actor)

      chat_blocks = load_chat_blocks(chat_id, actor)
      chat_tool_bindings = load_chat_tool_bindings(chat_id, actor)
      prompt_sources = load_prompt_sources(chat, chat_blocks, actor)
      compiled_prompt_text = compiled_prompt_text(chat, prompt_sources)
      tool_resolution = BindingResolver.resolve_for_chat(chat, actor)

      counters =
        ChatMetrics.counters_from_history(chat, messages, actor, prompt_sources: prompt_sources)

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
        prompt_sources: %{
          bot: Enum.map(prompt_sources.bot, &prompt_binding/1),
          chat: Enum.map(prompt_sources.chat, &prompt_binding/1),
          configuration: Enum.map(prompt_sources.configuration, &prompt_binding/1),
          user: Enum.map(prompt_sources.user, &prompt_binding/1)
        },
        compiled_prompt_text: compiled_prompt_text,
        counters: counters,
        active_tool_instances:
          Enum.map(tool_resolution.active_tool_instances, &Serializer.tool_instance_option/1),
        missing_required_per_user_tool_aliases: tool_resolution.missing_aliases,
        options: %{
          bots: Enum.map(bots, &Serializer.bot_option/1),
          llm_configurations: Enum.map(llm_configurations, &Serializer.configuration_option/1),
          knowledge_blocks: Enum.map(knowledge_blocks, &Serializer.knowledge_block_option/1),
          tool_instances: Enum.map(tool_instances, &Serializer.tool_instance_option/1)
        },
        active_generation_message_id: generating_message_id
      })
    end
  end

  def send(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      chat_id = String.to_integer(id)
      content = params |> Map.get("content", "") |> to_string()
      explicit_parent? = Map.has_key?(params, "parent_id")
      parent_id = Helpers.parse_optional_integer(Map.get(params, "parent_id"))
      upload_policy = ChatUploadPolicy.load_for_chat(chat_id, actor)

      with {:ok, prepared_uploads} <- ChatAttachments.parse_prepared_uploads(params),
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

      with message_id when is_integer(message_id) <- message_id,
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

      with message_id when is_integer(message_id) <- message_id,
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

              alias_value =
                item
                |> Map.get("alias", "")
                |> to_string()
                |> String.trim()

              enabled =
                case Map.get(item, "enabled", true) do
                  false -> false
                  "false" -> false
                  _ -> true
                end

              cond do
                not is_integer(tool_instance_id) ->
                  nil

                alias_value == "" ->
                  nil

                is_integer(id) and id > 0 ->
                  %{
                    id: id,
                    tool_instance_id: tool_instance_id,
                    alias: alias_value,
                    enabled: enabled,
                    sequence: index
                  }

                true ->
                  %{
                    tool_instance_id: tool_instance_id,
                    alias: alias_value,
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

  defp chat_message_count(chat) do
    case Map.get(chat, :message_count) do
      count when is_integer(count) and count >= 0 -> count
      _ -> 0
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
    |> Ash.Query.load([tool_instance: [:name, :type, :outlet_online, :can_edit]], strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_prompt_sources(chat, chat_blocks, actor) do
    %{
      bot: load_bot_prompt_blocks(chat.bot_id, actor),
      chat: Enum.filter(chat_blocks, &(&1.enabled == true)),
      configuration: load_configuration_prompt_blocks(chat.llm_configuration_id, actor),
      user: load_user_prompt_blocks(actor)
    }
  end

  defp compiled_prompt_text(chat, prompt_sources) do
    bot_blocks = prompt_blocks_from_bindings(Map.get(prompt_sources, :bot, []))
    chat_blocks = prompt_blocks_from_bindings(Map.get(prompt_sources, :chat, []))

    {config_top_blocks, config_bottom_blocks} =
      split_configuration_prompt_blocks(Map.get(prompt_sources, :configuration, []))

    user_blocks = prompt_blocks_from_bindings(Map.get(prompt_sources, :user, []))
    bot_variables = bot_variables(chat)

    SystemPrompt.build(
      bot_blocks: bot_blocks,
      chat_blocks: chat_blocks,
      config_top_blocks: config_top_blocks,
      config_bottom_blocks: config_bottom_blocks,
      user_blocks: user_blocks,
      bot_variables: bot_variables,
      chat_variables: chat.variables
    )
  end

  defp bot_variables(%{bot: %{variables: variables}}) when is_map(variables), do: variables
  defp bot_variables(_chat), do: %{}

  defp prompt_blocks_from_bindings(bindings) when is_list(bindings) do
    bindings
    |> Enum.map(&Map.get(&1, :knowledge_block))
    |> Enum.reject(&is_nil/1)
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

  defp load_bot_prompt_blocks(bot_id, actor) when is_integer(bot_id) do
    BotKnowledgeBlock
    |> Ash.Query.filter(bot_id == ^bot_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.select([:id, :bot_id, :knowledge_block_id, :enabled, :sequence])
    |> Ash.Query.load(Loads.prompt_source_binding(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_bot_prompt_blocks(_bot_id, _actor), do: []

  defp load_configuration_prompt_blocks(configuration_id, actor)
       when is_integer(configuration_id) do
    LlmConfigurationKnowledgeBlock
    |> Ash.Query.filter(llm_configuration_id == ^configuration_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.select([
      :id,
      :llm_configuration_id,
      :knowledge_block_id,
      :selection,
      :enabled,
      :sequence
    ])
    |> Ash.Query.load(Loads.prompt_source_binding(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_configuration_prompt_blocks(_configuration_id, _actor), do: []

  defp split_configuration_prompt_blocks(bindings) when is_list(bindings) do
    Enum.reduce(bindings, {[], []}, fn binding, {top, bottom} ->
      block = Map.get(binding, :knowledge_block)

      cond do
        is_nil(block) ->
          {top, bottom}

        binding_selection(binding) == :top ->
          {[block | top], bottom}

        true ->
          {top, [block | bottom]}
      end
    end)
    |> then(fn {top, bottom} -> {Enum.reverse(top), Enum.reverse(bottom)} end)
  end

  defp split_configuration_prompt_blocks(_other), do: {[], []}

  defp binding_selection(binding) when is_map(binding) do
    case Map.get(binding, :selection) do
      :top -> :top
      "top" -> :top
      _ -> :bottom
    end
  end

  defp load_user_prompt_blocks(%{id: owner_id} = actor) when is_integer(owner_id) do
    UserKnowledgeBlock
    |> Ash.Query.filter(owner_id == ^owner_id and enabled == true)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.select([:id, :knowledge_block_id, :enabled, :sequence])
    |> Ash.Query.load(Loads.prompt_source_binding(), strict?: true)
    |> Ash.read!(actor: actor)
  end

  defp load_user_prompt_blocks(_actor), do: []

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
end
