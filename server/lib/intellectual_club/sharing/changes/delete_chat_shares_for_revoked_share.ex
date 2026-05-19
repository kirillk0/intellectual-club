defmodule IntellectualClub.Sharing.Changes.DeleteChatSharesForRevokedShare do
  @moduledoc """
  Removes chat shares that depend on a revoked bot or configuration share.
  """

  use Ash.Resource.Change

  import Ecto.Query, only: [from: 2]

  alias Ash.Changeset
  alias IntellectualClub.Db

  @impl true
  def change(changeset, opts, _context) do
    resource = Keyword.fetch!(opts, :resource)
    context_key = {__MODULE__, resource, :share}

    changeset
    |> Changeset.before_action(fn changeset ->
      snapshot =
        case {resource, changeset.data} do
          {:bot, %{bot_id: bot_id, user_group_id: user_group_id}} ->
            %{bot_id: bot_id, user_group_id: user_group_id}

          {:llm_configuration, %{llm_configuration_id: configuration_id, user_group_id: group_id}} ->
            %{llm_configuration_id: configuration_id, user_group_id: group_id}

          _other ->
            %{}
        end

      Changeset.put_context(changeset, context_key, snapshot)
    end)
    |> Changeset.after_action(fn changeset, record ->
      changeset.context
      |> Map.get(context_key, %{})
      |> delete_dependent_chat_shares(resource)

      {:ok, record}
    end)
  end

  defp delete_dependent_chat_shares(
         %{bot_id: bot_id, user_group_id: user_group_id},
         :bot
       )
       when is_integer(bot_id) and is_integer(user_group_id) do
    Db.repo().delete_all(
      from(s in "chat_shares",
        where: s.bot_id == ^bot_id and s.user_group_id == ^user_group_id
      )
    )

    :ok
  end

  defp delete_dependent_chat_shares(
         %{llm_configuration_id: configuration_id, user_group_id: user_group_id},
         :llm_configuration
       )
       when is_integer(configuration_id) and is_integer(user_group_id) do
    Db.repo().delete_all(
      from(s in "chat_shares",
        where:
          s.llm_configuration_id == ^configuration_id and
            s.user_group_id == ^user_group_id
      )
    )

    :ok
  end

  defp delete_dependent_chat_shares(_snapshot, _resource), do: :ok
end
