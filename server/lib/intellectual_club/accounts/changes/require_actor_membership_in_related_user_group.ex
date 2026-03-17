defmodule IntellectualClub.Accounts.Changes.RequireActorMembershipInRelatedUserGroup do
  @moduledoc """
  Ensures that the actor is a member of the selected `user_group` relationship.
  """

  use Ash.Resource.Change

  alias Ash.{Changeset, Resource}
  alias IntellectualClub.Accounts.UserGroup

  @impl true
  def change(changeset, opts, _context) do
    relationship_name = Keyword.get(opts, :relationship, :user_group)
    required? = Keyword.get(opts, :required?, true)

    Changeset.before_action(changeset, fn changeset ->
      actor = changeset.context[:private][:actor]
      relationship = Resource.Info.relationship(changeset.resource, relationship_name)

      cond do
        is_nil(actor) ->
          Changeset.add_error(changeset, message: "Actor is required")

        is_nil(relationship) ->
          Changeset.add_error(changeset,
            message: "Unknown relationship #{inspect(relationship_name)}"
          )

        true ->
          group_id_field = relationship.source_attribute
          group_id = Changeset.get_attribute(changeset, group_id_field)

          cond do
            is_nil(group_id) and required? ->
              Changeset.add_error(changeset, field: group_id_field, message: "is required")

            is_nil(group_id) ->
              changeset

            actor_member_of_group?(group_id, actor.id) ->
              changeset

            true ->
              Changeset.add_error(changeset,
                field: group_id_field,
                message: "is invalid or not accessible"
              )
          end
      end
    end)
  end

  defp actor_member_of_group?(group_id, actor_id)
       when is_integer(group_id) and group_id > 0 and is_integer(actor_id) and actor_id > 0 do
    UserGroup
    |> Ash.Query.filter(id == ^group_id and exists(memberships, user_id == ^actor_id))
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  defp actor_member_of_group?(_group_id, _actor_id), do: false
end
