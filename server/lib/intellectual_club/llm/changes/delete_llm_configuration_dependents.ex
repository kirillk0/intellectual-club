defmodule IntellectualClub.Llm.Changes.DeleteLlmConfigurationDependents do
  @moduledoc """
  Cleans records that reference an LLM configuration before deletion.

  Database foreign keys are non-cascading for:
  - `llm_configuration_knowledge_blocks.llm_configuration_id -> llm_configurations.id`
  - `bots.default_llm_configuration_id -> llm_configurations.id`
  - `chats.llm_configuration_id -> llm_configurations.id`
  - `chat_messages.llm_configuration_id -> llm_configurations.id`
  """

  use Ash.Resource.Change

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Db

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      repo = Db.repo()
      llm_configuration_id = changeset.data.id
      owner_id = actor_id(changeset.context[:private][:actor])

      delete_configuration_bindings(repo, llm_configuration_id, owner_id)
      clear_bot_default_configuration_reference(repo, llm_configuration_id, owner_id)
      clear_chat_configuration_reference(repo, llm_configuration_id, owner_id)
      clear_message_configuration_reference(repo, llm_configuration_id, owner_id)

      changeset
    end)
  end

  defp actor_id(%{id: id}) when is_integer(id), do: id
  defp actor_id(_), do: nil

  defp delete_configuration_bindings(repo, llm_configuration_id, owner_id)
       when is_integer(owner_id) do
    _ =
      repo.delete_all(
        from(lkb in "llm_configuration_knowledge_blocks",
          where: lkb.llm_configuration_id == ^llm_configuration_id and lkb.owner_id == ^owner_id
        )
      )

    :ok
  end

  defp delete_configuration_bindings(_repo, _llm_configuration_id, _owner_id), do: :ok

  defp clear_bot_default_configuration_reference(repo, llm_configuration_id, owner_id)
       when is_integer(owner_id) do
    _ =
      repo.update_all(
        from(b in "bots",
          where:
            b.default_llm_configuration_id == ^llm_configuration_id and b.owner_id == ^owner_id
        ),
        set: [default_llm_configuration_id: nil]
      )

    :ok
  end

  defp clear_bot_default_configuration_reference(_repo, _llm_configuration_id, _owner_id), do: :ok

  defp clear_chat_configuration_reference(repo, llm_configuration_id, owner_id)
       when is_integer(owner_id) do
    _ =
      repo.update_all(
        from(c in "chats",
          where: c.llm_configuration_id == ^llm_configuration_id and c.owner_id == ^owner_id
        ),
        set: [llm_configuration_id: nil]
      )

    :ok
  end

  defp clear_chat_configuration_reference(_repo, _llm_configuration_id, _owner_id), do: :ok

  defp clear_message_configuration_reference(repo, llm_configuration_id, owner_id)
       when is_integer(owner_id) do
    _ =
      repo.update_all(
        from(m in "chat_messages",
          where: m.llm_configuration_id == ^llm_configuration_id and m.owner_id == ^owner_id
        ),
        set: [llm_configuration_id: nil]
      )

    :ok
  end

  defp clear_message_configuration_reference(_repo, _llm_configuration_id, _owner_id), do: :ok
end
