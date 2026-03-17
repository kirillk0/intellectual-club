defmodule IntellectualClub.Tools.Changes.DeleteToolDependents do
  @moduledoc """
  Cleans records that reference a tool instance before deletion.

  Database foreign keys are non-cascading for:
  - `tool_functions.tool_instance_id -> tool_instances.id`
  - `bot_tool_bindings.tool_instance_id -> tool_instances.id`
  - `bot_user_tool_bindings.tool_instance_id -> tool_instances.id`
  - `outlet_pairing_requests.tool_instance_id -> tool_instances.id`
  """

  use Ash.Resource.Change

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Db

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      repo = Db.repo()
      tool_instance_id = changeset.data.id

      delete_tool_functions(repo, tool_instance_id)
      delete_bot_tool_bindings(repo, tool_instance_id)
      delete_bot_user_tool_bindings(repo, tool_instance_id)
      clear_outlet_pairing_requests(repo, tool_instance_id)

      changeset
    end)
  end

  defp delete_tool_functions(repo, tool_instance_id) when is_integer(tool_instance_id) do
    _ =
      repo.delete_all(
        from(tf in "tool_functions", where: tf.tool_instance_id == ^tool_instance_id)
      )

    :ok
  end

  defp delete_tool_functions(_repo, _tool_instance_id), do: :ok

  defp delete_bot_tool_bindings(repo, tool_instance_id) when is_integer(tool_instance_id) do
    _ =
      repo.delete_all(
        from(btb in "bot_tool_bindings", where: btb.tool_instance_id == ^tool_instance_id)
      )

    :ok
  end

  defp delete_bot_tool_bindings(_repo, _tool_instance_id), do: :ok

  defp delete_bot_user_tool_bindings(repo, tool_instance_id) when is_integer(tool_instance_id) do
    _ =
      repo.delete_all(
        from(butb in "bot_user_tool_bindings", where: butb.tool_instance_id == ^tool_instance_id)
      )

    :ok
  end

  defp delete_bot_user_tool_bindings(_repo, _tool_instance_id), do: :ok

  defp clear_outlet_pairing_requests(repo, tool_instance_id) when is_integer(tool_instance_id) do
    _ =
      repo.update_all(
        from(pr in "outlet_pairing_requests", where: pr.tool_instance_id == ^tool_instance_id),
        set: [tool_instance_id: nil]
      )

    :ok
  end

  defp clear_outlet_pairing_requests(_repo, _tool_instance_id), do: :ok
end
