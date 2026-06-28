defmodule IntellectualClub.Sharing do
  @moduledoc """
  High-level sharing operations for bots, chats, and LLM configurations.
  """

  alias IntellectualClub.Accounts.UserGroup
  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotShare
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatKnowledgeBlock
  alias IntellectualClub.Chat.ChatShare
  alias IntellectualClub.Repo
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationShare
  alias IntellectualClub.Tools.BotToolBinding
  alias IntellectualClub.Tools.ChatToolBinding

  require Ash.Query

  @tool_modes [:shared, :per_user]

  def list_actor_groups(actor) do
    UserGroup
    |> Ash.Query.filter(exists(memberships, user_id == ^actor.id))
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.read(actor: actor)
  end

  def get_bot_share_state(bot_id, actor) when is_integer(bot_id) do
    with {:ok, bot} <- fetch_owned_bot(bot_id, actor) do
      {:ok, load_bot_share_state(bot, actor)}
    end
  end

  def replace_bot_share_state(bot_id, group_ids, tool_modes, actor)
      when is_integer(bot_id) and is_list(group_ids) and is_map(tool_modes) do
    with {:ok, bot} <- fetch_owned_bot(bot_id, actor),
         {:ok, allowed_group_ids} <- validate_group_ids(group_ids, actor),
         {:ok, normalized_tool_modes} <- validate_tool_modes(tool_modes) do
      transaction(fn repo ->
        with :ok <- replace_bot_shares(bot, allowed_group_ids, actor),
             :ok <- replace_bot_tool_modes(bot, normalized_tool_modes, actor) do
          load_bot_share_state(bot, actor)
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)
    end
  end

  def get_llm_configuration_share_state(configuration_id, actor)
      when is_integer(configuration_id) do
    with {:ok, configuration} <- fetch_owned_llm_configuration(configuration_id, actor) do
      {:ok, load_llm_configuration_share_state(configuration, actor)}
    end
  end

  def get_chat_share_state(chat_id, actor) when is_integer(chat_id) do
    with {:ok, chat} <- fetch_owned_chat(chat_id, actor) do
      {:ok, load_chat_share_state(chat, actor)}
    end
  end

  def replace_chat_share_state(chat_id, group_ids, actor)
      when is_integer(chat_id) and is_list(group_ids) do
    with {:ok, chat} <- fetch_owned_chat(chat_id, actor),
         {:ok, allowed_group_ids} <- validate_group_ids(group_ids, actor),
         :ok <- validate_chat_share_request(chat, allowed_group_ids, actor) do
      transaction(fn repo ->
        with :ok <- replace_chat_shares(chat, allowed_group_ids, actor) do
          load_chat_share_state(chat, actor)
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)
    end
  end

  def replace_llm_configuration_share_state(configuration_id, group_ids, actor)
      when is_integer(configuration_id) and is_list(group_ids) do
    with {:ok, configuration} <- fetch_owned_llm_configuration(configuration_id, actor),
         {:ok, allowed_group_ids} <- validate_group_ids(group_ids, actor) do
      transaction(fn repo ->
        with :ok <- replace_llm_configuration_shares(configuration, allowed_group_ids, actor) do
          load_llm_configuration_share_state(configuration, actor)
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)
    end
  end

  defp transaction(fun) when is_function(fun, 1) do
    repo = Repo

    case repo.transaction(fn -> fun.(repo) end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_owned_bot(bot_id, actor) do
    case Ash.get(Bot, bot_id, actor: actor) do
      {:ok, %Bot{owner_id: owner_id} = bot} when owner_id == actor.id -> {:ok, bot}
      {:ok, %Bot{}} -> {:error, :forbidden}
      {:ok, nil} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_owned_llm_configuration(configuration_id, actor) do
    case Ash.get(LlmConfiguration, configuration_id, actor: actor) do
      {:ok, %LlmConfiguration{owner_id: owner_id} = configuration} when owner_id == actor.id ->
        {:ok, configuration}

      {:ok, %LlmConfiguration{}} ->
        {:error, :forbidden}

      {:ok, nil} ->
        {:error, :not_found}

      {:error, %Ash.Error.Query.NotFound{}} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_owned_chat(chat_id, actor) do
    case Ash.get(Chat, chat_id, actor: actor) do
      {:ok, %Chat{owner_id: owner_id} = chat} when owner_id == actor.id -> {:ok, chat}
      {:ok, %Chat{}} -> {:error, :forbidden}
      {:ok, nil} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_group_ids(group_ids, actor) do
    requested_group_ids =
      group_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.filter(&(&1 > 0))
      |> Enum.uniq()

    case requested_group_ids do
      [] ->
        {:ok, []}

      _group_ids ->
        groups =
          UserGroup
          |> Ash.Query.filter(id in ^requested_group_ids)
          |> Ash.Query.filter(exists(memberships, user_id == ^actor.id))
          |> Ash.read!(actor: actor)

        readable_group_ids = groups |> Enum.map(& &1.id) |> MapSet.new()
        requested_group_ids_set = MapSet.new(requested_group_ids)

        if MapSet.equal?(requested_group_ids_set, readable_group_ids) do
          {:ok, Enum.sort(requested_group_ids)}
        else
          {:error, {:validation, "You can only share to your own groups."}}
        end
    end
  end

  defp validate_tool_modes(tool_modes) when map_size(tool_modes) == 0, do: {:ok, %{}}

  defp validate_tool_modes(tool_modes) do
    tool_modes
    |> Enum.reduce_while({:ok, %{}}, fn {raw_binding_id, raw_mode}, {:ok, acc} ->
      with {:ok, binding_id} <- parse_binding_id(raw_binding_id),
           {:ok, mode} <- parse_tool_mode(raw_mode) do
        {:cont, {:ok, Map.put(acc, binding_id, mode)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_binding_id(binding_id) when is_integer(binding_id) and binding_id > 0,
    do: {:ok, binding_id}

  defp parse_binding_id(binding_id) when is_binary(binding_id) do
    case Integer.parse(binding_id) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, {:validation, "tool_modes must use persisted bot tool binding IDs."}}
    end
  end

  defp parse_binding_id(_other),
    do: {:error, {:validation, "tool_modes must use persisted bot tool binding IDs."}}

  defp parse_tool_mode(mode) when mode in @tool_modes, do: {:ok, mode}

  defp parse_tool_mode(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> String.to_existing_atom()
    |> parse_tool_mode()
  rescue
    ArgumentError ->
      {:error, {:validation, "tool_modes values must be shared or per_user."}}
  end

  defp parse_tool_mode(_other),
    do: {:error, {:validation, "tool_modes values must be shared or per_user."}}

  defp load_bot_share_state(bot, actor) do
    shares =
      BotShare
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.Query.sort(user_group_id: :asc)
      |> Ash.read!(actor: actor)

    tool_modes =
      BotToolBinding
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.Query.sort(sequence: :asc, id: :asc)
      |> Ash.read!(actor: actor)
      |> Map.new(fn binding ->
        {Integer.to_string(binding.id), Atom.to_string(binding.sharing_mode)}
      end)

    %{
      group_ids: Enum.map(shares, & &1.user_group_id),
      tool_modes: tool_modes
    }
  end

  defp load_llm_configuration_share_state(configuration, actor) do
    shares =
      LlmConfigurationShare
      |> Ash.Query.filter(llm_configuration_id == ^configuration.id)
      |> Ash.Query.sort(user_group_id: :asc)
      |> Ash.read!(actor: actor)

    %{
      group_ids: Enum.map(shares, & &1.user_group_id)
    }
  end

  defp load_chat_share_state(chat, actor) do
    shares =
      ChatShare
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.Query.sort(user_group_id: :asc)
      |> Ash.read!(actor: actor)

    eligibility = chat_share_group_eligibility(chat, actor)

    %{
      group_ids: Enum.map(shares, & &1.user_group_id),
      eligible_group_ids:
        eligibility
        |> Enum.filter(& &1.eligible)
        |> Enum.map(& &1.id),
      group_eligibility: eligibility
    }
  end

  defp replace_bot_shares(bot, requested_group_ids, actor) do
    existing_shares =
      BotShare
      |> Ash.Query.filter(bot_id == ^bot.id)
      |> Ash.read!(actor: actor)

    existing_by_group_id = Map.new(existing_shares, &{&1.user_group_id, &1})
    requested_group_ids_set = MapSet.new(requested_group_ids)

    existing_shares
    |> Enum.reject(&MapSet.member?(requested_group_ids_set, &1.user_group_id))
    |> Enum.reduce_while(:ok, fn share, :ok ->
      case share
           |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
           |> Ash.destroy() do
        :ok -> {:cont, :ok}
        {:ok, _share} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      :ok ->
        requested_group_ids
        |> Enum.reject(&Map.has_key?(existing_by_group_id, &1))
        |> Enum.reduce_while(:ok, fn group_id, :ok ->
          case BotShare
               |> Ash.Changeset.for_create(
                 :create,
                 %{bot_id: bot.id, user_group_id: group_id},
                 actor: actor
               )
               |> Ash.create() do
            {:ok, _share} -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  defp replace_llm_configuration_shares(configuration, requested_group_ids, actor) do
    existing_shares =
      LlmConfigurationShare
      |> Ash.Query.filter(llm_configuration_id == ^configuration.id)
      |> Ash.read!(actor: actor)

    existing_by_group_id = Map.new(existing_shares, &{&1.user_group_id, &1})
    requested_group_ids_set = MapSet.new(requested_group_ids)

    existing_shares
    |> Enum.reject(&MapSet.member?(requested_group_ids_set, &1.user_group_id))
    |> Enum.reduce_while(:ok, fn share, :ok ->
      case share
           |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
           |> Ash.destroy() do
        :ok -> {:cont, :ok}
        {:ok, _share} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      :ok ->
        requested_group_ids
        |> Enum.reject(&Map.has_key?(existing_by_group_id, &1))
        |> Enum.reduce_while(:ok, fn group_id, :ok ->
          case LlmConfigurationShare
               |> Ash.Changeset.for_create(
                 :create,
                 %{llm_configuration_id: configuration.id, user_group_id: group_id},
                 actor: actor
               )
               |> Ash.create() do
            {:ok, _share} -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_chat_share_request(_chat, [], _actor), do: :ok

  defp validate_chat_share_request(chat, group_ids, actor) do
    with :ok <- validate_chat_shareable(chat, actor),
         :ok <- validate_chat_dependencies_shared(chat, group_ids, actor) do
      :ok
    end
  end

  defp validate_chat_shareable(%Chat{bot_id: bot_id}, _actor) when not is_integer(bot_id) do
    {:error, {:validation, "Chat must have a bot before it can be shared."}}
  end

  defp validate_chat_shareable(%Chat{llm_configuration_id: configuration_id}, _actor)
       when not is_integer(configuration_id) do
    {:error, {:validation, "Chat must have a configuration before it can be shared."}}
  end

  defp validate_chat_shareable(%Chat{} = chat, actor) do
    cond do
      chat_has_knowledge_blocks?(chat, actor) ->
        {:error, {:validation, "Chats with chat blocks cannot be shared yet."}}

      chat_has_tool_bindings?(chat, actor) ->
        {:error, {:validation, "Chats with chat tools cannot be shared yet."}}

      true ->
        :ok
    end
  end

  defp validate_chat_dependencies_shared(%Chat{} = chat, group_ids, actor) do
    bot_group_ids =
      BotShare
      |> Ash.Query.filter(bot_id == ^chat.bot_id and user_group_id in ^group_ids)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.user_group_id)
      |> MapSet.new()

    configuration_group_ids =
      LlmConfigurationShare
      |> Ash.Query.filter(
        llm_configuration_id == ^chat.llm_configuration_id and user_group_id in ^group_ids
      )
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.user_group_id)
      |> MapSet.new()

    requested = MapSet.new(group_ids)

    if MapSet.subset?(requested, bot_group_ids) and
         MapSet.subset?(requested, configuration_group_ids) do
      :ok
    else
      {:error,
       {:validation,
        "You can only share this chat with groups that already have access to its bot and configuration."}}
    end
  end

  defp replace_chat_shares(chat, requested_group_ids, actor) do
    existing_shares =
      ChatShare
      |> Ash.Query.filter(chat_id == ^chat.id)
      |> Ash.read!(actor: actor)

    requested_group_ids_set = MapSet.new(requested_group_ids)

    {stale_or_removed, reusable} =
      Enum.split_with(existing_shares, fn share ->
        not MapSet.member?(requested_group_ids_set, share.user_group_id) or
          share.bot_id != chat.bot_id or
          share.llm_configuration_id != chat.llm_configuration_id
      end)

    reusable_by_group_id = Map.new(reusable, &{&1.user_group_id, &1})

    stale_or_removed
    |> Enum.reduce_while(:ok, fn share, :ok ->
      case share
           |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
           |> Ash.destroy() do
        :ok -> {:cont, :ok}
        {:ok, _share} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      :ok ->
        requested_group_ids
        |> Enum.reject(&Map.has_key?(reusable_by_group_id, &1))
        |> Enum.reduce_while(:ok, fn group_id, :ok ->
          case ChatShare
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   chat_id: chat.id,
                   user_group_id: group_id,
                   bot_id: chat.bot_id,
                   llm_configuration_id: chat.llm_configuration_id
                 },
                 actor: actor
               )
               |> Ash.create() do
            {:ok, _share} -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end

  defp chat_share_group_eligibility(%Chat{} = chat, actor) do
    groups = list_actor_groups(actor) |> elem_or_empty()
    bot_group_ids = shared_bot_group_id_set(chat.bot_id, actor)
    configuration_group_ids = shared_configuration_group_id_set(chat.llm_configuration_id, actor)
    shareable_result = validate_chat_shareable(chat, actor)

    Enum.map(groups, fn group ->
      reason =
        cond do
          shareable_result != :ok ->
            validation_message(shareable_result)

          not MapSet.member?(bot_group_ids, group.id) ->
            "Share the chat bot with this group first."

          not MapSet.member?(configuration_group_ids, group.id) ->
            "Share the chat configuration with this group first."

          true ->
            nil
        end

      %{
        id: group.id,
        eligible: is_nil(reason),
        disabled_reason: reason
      }
    end)
  end

  defp elem_or_empty({:ok, values}) when is_list(values), do: values
  defp elem_or_empty(_other), do: []

  defp shared_bot_group_id_set(bot_id, actor) when is_integer(bot_id) do
    BotShare
    |> Ash.Query.filter(bot_id == ^bot_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.user_group_id)
    |> MapSet.new()
  end

  defp shared_bot_group_id_set(_bot_id, _actor), do: MapSet.new()

  defp shared_configuration_group_id_set(configuration_id, actor)
       when is_integer(configuration_id) do
    LlmConfigurationShare
    |> Ash.Query.filter(llm_configuration_id == ^configuration_id)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.user_group_id)
    |> MapSet.new()
  end

  defp shared_configuration_group_id_set(_configuration_id, _actor), do: MapSet.new()

  defp chat_has_knowledge_blocks?(%Chat{} = chat, actor) do
    ChatKnowledgeBlock
    |> Ash.Query.filter(chat_id == ^chat.id)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: actor)
    |> Enum.any?()
  end

  defp chat_has_tool_bindings?(%Chat{} = chat, actor) do
    ChatToolBinding
    |> Ash.Query.filter(chat_id == ^chat.id)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: actor)
    |> Enum.any?()
  end

  defp validation_message({:error, {:validation, message}}) when is_binary(message), do: message

  defp replace_bot_tool_modes(_bot, tool_modes, _actor) when map_size(tool_modes) == 0, do: :ok

  defp replace_bot_tool_modes(bot, tool_modes, actor) do
    binding_ids = Map.keys(tool_modes)

    bindings =
      BotToolBinding
      |> Ash.Query.filter(bot_id == ^bot.id and id in ^binding_ids)
      |> Ash.read!(actor: actor)

    if length(bindings) != length(binding_ids) do
      {:error, {:validation, "tool_modes contains unknown bot tool bindings."}}
    else
      bindings
      |> Enum.reduce_while(:ok, fn binding, :ok ->
        mode = Map.fetch!(tool_modes, binding.id)

        if binding.sharing_mode == mode do
          {:cont, :ok}
        else
          case binding
               |> Ash.Changeset.for_update(:update, %{sharing_mode: mode}, actor: actor)
               |> Ash.update() do
            {:ok, _binding} -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end
      end)
    end
  end
end
