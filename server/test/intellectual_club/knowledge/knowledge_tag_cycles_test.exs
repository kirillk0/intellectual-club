defmodule IntellectualClub.Knowledge.KnowledgeTagCyclesTest do
  @moduledoc """
  Tests for cycle prevention in knowledge tag hierarchies.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Knowledge.KnowledgeTag

  test "cannot set parent to a descendant tag" do
    %{user: actor} = user_fixture()

    root =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Root", parent_id: nil}, actor: actor)
      |> Ash.create!(actor: actor)

    child =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Child", parent_id: root.id}, actor: actor)
      |> Ash.create!(actor: actor)

    grandchild =
      KnowledgeTag
      |> Ash.Changeset.for_create(:create, %{name: "Grandchild", parent_id: child.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    root
    |> Ash.Changeset.for_update(:update, %{parent_id: grandchild.id}, actor: actor)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _tag} ->
        flunk("expected cycle validation to fail")

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        assert Enum.any?(errors, fn
                 %Ash.Error.Changes.InvalidAttribute{field: :parent_id} -> true
                 _ -> false
               end)
    end
  end
end
