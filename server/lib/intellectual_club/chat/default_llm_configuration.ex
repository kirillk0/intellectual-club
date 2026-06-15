defmodule IntellectualClub.Chat.DefaultLlmConfiguration do
  @moduledoc """
  Selects a default LLM configuration for new chats and bot changes.
  """

  alias IntellectualClub.Bots.Bot
  alias IntellectualClub.Bots.BotCompatibleConfigurationTag
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationTag
  alias IntellectualClub.Llm.LlmConfigurationTagBinding

  require Ash.Query

  @spec default_id(map(), integer() | nil) :: integer() | nil
  def default_id(actor, bot_id) do
    available_configurations = available_for_bot(actor, bot_id)

    latest_chat_llm_configuration_id(
      actor,
      bot_id,
      Enum.map(available_configurations, & &1.id)
    ) ||
      bot_default_llm_configuration_id(actor, bot_id) ||
      first_available_llm_configuration_id(available_configurations)
  end

  @spec maybe_put_default_on_create(Ash.Changeset.t()) :: Ash.Changeset.t()
  def maybe_put_default_on_create(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :llm_configuration_id) do
      changeset
    else
      actor = changeset.context[:private][:actor]
      bot_id = Ash.Changeset.get_attribute(changeset, :bot_id)

      case default_id(actor, bot_id) do
        nil ->
          changeset

        llm_configuration_id ->
          Ash.Changeset.change_attribute(changeset, :llm_configuration_id, llm_configuration_id)
      end
    end
  end

  @spec maybe_adjust_for_bot_change(Ash.Changeset.t()) :: Ash.Changeset.t()
  def maybe_adjust_for_bot_change(changeset) do
    cond do
      Ash.Changeset.changing_attribute?(changeset, :llm_configuration_id) ->
        changeset

      not Ash.Changeset.changing_attribute?(changeset, :bot_id) ->
        changeset

      not is_integer(Ash.Changeset.get_data(changeset, :llm_configuration_id)) ->
        changeset

      true ->
        actor = changeset.context[:private][:actor]
        bot_id = Ash.Changeset.get_attribute(changeset, :bot_id)
        current_llm_configuration_id = Ash.Changeset.get_data(changeset, :llm_configuration_id)

        if compatible_with_bot?(actor, bot_id, current_llm_configuration_id) do
          changeset
        else
          Ash.Changeset.change_attribute(
            changeset,
            :llm_configuration_id,
            default_id(actor, bot_id)
          )
        end
    end
  end

  @spec available_for_bot(map(), integer() | nil) :: [LlmConfiguration.t()]
  def available_for_bot(actor, bot_id) do
    enabled_configurations =
      actor
      |> load_llm_configurations()
      |> Enum.filter(&(&1.enabled == true))

    case compatible_ids_for_bot(actor, bot_id) do
      :all -> enabled_configurations
      compatible_ids -> Enum.filter(enabled_configurations, &(&1.id in compatible_ids))
    end
  end

  @spec compatible_with_bot?(map(), integer() | nil, integer() | nil) :: boolean()
  def compatible_with_bot?(_actor, bot_id, _llm_configuration_id) when not is_integer(bot_id),
    do: true

  def compatible_with_bot?(_actor, _bot_id, llm_configuration_id)
      when not is_integer(llm_configuration_id),
      do: true

  def compatible_with_bot?(actor, bot_id, llm_configuration_id) do
    case compatible_ids_for_bot(actor, bot_id) do
      :all -> true
      compatible_ids -> llm_configuration_id in compatible_ids
    end
  end

  @spec compatible_ids_for_bot(map(), integer() | nil) :: :all | [integer()]
  def compatible_ids_for_bot(_actor, bot_id) when not is_integer(bot_id), do: :all

  def compatible_ids_for_bot(actor, bot_id) do
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
        if accessible_llm_configuration?(actor, llm_configuration_id), do: llm_configuration_id

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

  defp latest_chat_llm_configuration_id(_actor, _bot_id, []), do: nil

  defp latest_chat_llm_configuration_id(actor, bot_id, available_ids) do
    Chat
    |> maybe_apply_chat_filter(bot_id)
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

  defp maybe_apply_chat_filter(query, bot_id) when is_integer(bot_id) do
    Ash.Query.filter(query, bot_id == ^bot_id)
  end

  defp maybe_apply_chat_filter(query, nil), do: Ash.Query.filter(query, is_nil(bot_id))
  defp maybe_apply_chat_filter(query, _other), do: query

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
        case normalize_tag_name(Map.get(binding, :tag_name)) do
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
        tag.id in tag_ids or normalize_tag_name(tag.name) in tag_names
      end)
      |> Enum.map(& &1.id)

    (tag_ids ++ matching_tag_ids)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_tag_name(name) when is_binary(name) do
    case name |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tag_name(_other), do: nil

  defp load_llm_configurations(actor) do
    LlmConfiguration
    |> Ash.Query.sort(model_name: :asc, updated_at: :desc)
    |> Ash.read!(actor: actor)
  end
end
