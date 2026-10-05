defmodule IntellectualClub.Fixtures do
  @moduledoc """
  Building blocks shared by the domain fixture modules.

  Conventions used by every `*Fixtures` module under `test/support/fixtures`:

    * the actor comes first, then the parent records, then `attrs`;
    * `attrs` may be a map or a keyword list and is merged over the defaults
      of the most common test scenario, so a call site only spells out what
      matters for the test;
    * records are created through public Ash actions with the given actor, so
      policies and changes run exactly as in production code.

  `IntellectualClub.DataCase` and `IntellectualClubWeb.ConnCase` import this
  module together with the domain fixtures.
  """

  @doc """
  Creates `resource` through `action` (default `:create`) as `actor`.

      create!(ChatShare, %{chat_id: chat.id, user_group_id: group.id}, owner)
      create!(ChatMessage, :add_message, %{chat_id: chat.id, role: :user}, owner)
  """
  def create!(resource, action \\ :create, attrs, actor) do
    resource
    |> Ash.Changeset.for_create(action, to_attrs(attrs), actor: actor)
    |> Ash.create!(actor: actor)
  end

  @doc """
  Like `create!/4`, but attributes the action does not accept are force-set
  after the action input is cast (e.g. internal fork bookkeeping columns).
  """
  def create_forcing!(resource, action, attrs, actor) do
    attrs = to_attrs(attrs)
    action_info = Ash.Resource.Info.action(resource, action)
    inputs = MapSet.new(action_info.accept ++ Enum.map(action_info.arguments, & &1.name))
    {public, internal} = Map.split(attrs, Enum.filter(Map.keys(attrs), &(&1 in inputs)))

    resource
    |> Ash.Changeset.for_create(action, public, actor: actor)
    |> Ash.Changeset.force_change_attributes(internal)
    |> Ash.create!(actor: actor)
  end

  @doc "Returns `\"<prefix> <unique positive integer>\"`."
  def unique_name(prefix), do: "#{prefix} #{System.unique_integer([:positive])}"

  @doc "Normalizes fixture attributes given as a map or a keyword list into a map."
  def to_attrs(attrs) when is_map(attrs), do: attrs
  def to_attrs(attrs) when is_list(attrs), do: Map.new(attrs)

  @doc "Merges `attrs` (map or keyword list) over the `defaults` map."
  def merge_attrs(defaults, attrs) when is_map(defaults), do: Map.merge(defaults, to_attrs(attrs))

  @doc "Returns the id of a record, or the value itself when it already is an id."
  def id_of(%{id: id}), do: id
  def id_of(id) when is_integer(id) or is_binary(id), do: id
end
