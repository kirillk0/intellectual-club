defmodule IntellectualClub.Tools.Changes.RequireToolInstanceUsableByActor do
  @moduledoc """
  Requires a tool instance to be owned by or directly shared with the actor.

  Transitive visibility through another shared bot does not make a tool reusable
  in a different bot or chat.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      actor = changeset.context[:private][:actor]
      tool_instance_id = Changeset.get_attribute(changeset, :tool_instance_id)

      cond do
        is_nil(actor) ->
          Changeset.add_error(changeset, message: "Actor is required")

        not is_integer(tool_instance_id) ->
          Changeset.add_error(changeset, field: :tool_instance_id, message: "is required")

        usable_by_actor?(tool_instance_id, actor.id) ->
          changeset

        true ->
          Changeset.add_error(changeset,
            field: :tool_instance_id,
            message: "is invalid or not directly shared"
          )
      end
    end)
  end

  defp usable_by_actor?(tool_instance_id, actor_id)
       when is_integer(tool_instance_id) and is_integer(actor_id) do
    ToolInstance
    |> Ash.Query.filter(
      id == ^tool_instance_id and
        (owner_id == ^actor_id or
           exists(shares.user_group.memberships, user_id == ^actor_id))
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  defp usable_by_actor?(_tool_instance_id, _actor_id), do: false
end
