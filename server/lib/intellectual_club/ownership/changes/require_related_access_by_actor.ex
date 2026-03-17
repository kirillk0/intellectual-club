defmodule IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor do
  @moduledoc """
  Ensures that the actor has the required access level to belongs_to relationships.

  Supported access levels:

  * `:readable` - the actor must be able to read the related record
  * `:writable` - the actor must be able to update or destroy the related record
  """

  use Ash.Resource.Change

  alias Ash.{Changeset, Resource}

  @type access_mode :: :readable | :writable

  @impl true
  def change(changeset, opts, _context) do
    relationships =
      opts
      |> Keyword.fetch!(:relationships)
      |> List.wrap()

    required? = Keyword.get(opts, :required?, true)
    default_access = default_access_mode(opts)
    relationship_access = relationship_access_map(opts)

    Changeset.before_action(changeset, fn changeset ->
      actor = changeset.context[:private][:actor]

      cond do
        is_nil(actor) ->
          Changeset.add_error(changeset, message: "Actor is required")

        true ->
          Enum.reduce(relationships, changeset, fn relationship_name, changeset ->
            relationship = Resource.Info.relationship(changeset.resource, relationship_name)

            if is_nil(relationship) do
              Changeset.add_error(changeset,
                message: "Unknown relationship #{inspect(relationship_name)}"
              )
            else
              id_field = relationship.source_attribute
              related_id = Changeset.get_attribute(changeset, id_field)
              access = Map.get(relationship_access, relationship_name, default_access)

              cond do
                is_nil(related_id) and required? ->
                  Changeset.add_error(changeset, field: id_field, message: "is required")

                is_nil(related_id) ->
                  changeset

                accessible_by_actor?(relationship.destination, related_id, actor, access) ->
                  changeset

                true ->
                  Changeset.add_error(changeset,
                    field: id_field,
                    message: "is invalid or not accessible"
                  )
              end
            end
          end)
      end
    end)
  end

  defp relationship_access_map(opts) do
    case Keyword.get(opts, :access, :writable) do
      mode when mode in [:readable, :writable] ->
        %{}

      %{} = access_map ->
        normalize_access_map(access_map)

      access_list when is_list(access_list) ->
        access_list
        |> Enum.into(%{})
        |> normalize_access_map()

      other ->
        raise ArgumentError, "Invalid access option: #{inspect(other)}"
    end
  end

  defp default_access_mode(opts) do
    case Keyword.get(opts, :access, :writable) do
      mode when mode in [:readable, :writable] -> mode
      %{} -> :writable
      access_list when is_list(access_list) -> :writable
      other -> raise ArgumentError, "Invalid access option: #{inspect(other)}"
    end
  end

  defp normalize_access_map(access_map) do
    Enum.reduce(access_map, %{}, fn {relationship_name, access}, acc ->
      Map.put(acc, relationship_name, normalize_access(access))
    end)
  end

  defp normalize_access(access) when access in [:readable, :writable], do: access

  defp normalize_access(other) do
    raise ArgumentError, "Unsupported relationship access mode: #{inspect(other)}"
  end

  defp accessible_by_actor?(destination, related_id, actor, access) do
    case Ash.get(destination, related_id, actor: actor) do
      {:ok, record} when not is_nil(record) and access == :readable ->
        true

      {:ok, record} when not is_nil(record) ->
        case action_name(destination, access) do
          nil -> false
          action -> Ash.can?({record, action}, actor)
        end

      _other ->
        false
    end
  end

  defp action_name(destination, :readable) do
    destination
    |> Resource.Info.primary_action(:read)
    |> case do
      %{name: name} -> name
      _ -> Resource.Info.action(destination, :read) |> extract_action_name()
    end
  end

  defp action_name(destination, :writable) do
    destination
    |> Resource.Info.primary_action(:update)
    |> extract_action_name()
    |> case do
      nil ->
        Resource.Info.action(destination, :update)
        |> extract_action_name()

      name ->
        name
    end
    |> case do
      nil ->
        destination
        |> Resource.Info.primary_action(:destroy)
        |> extract_action_name()

      name ->
        name
    end
    |> case do
      nil ->
        Resource.Info.action(destination, :destroy)
        |> extract_action_name()

      name ->
        name
    end
  end

  defp extract_action_name(%{name: name}), do: name
  defp extract_action_name(_other), do: nil
end
