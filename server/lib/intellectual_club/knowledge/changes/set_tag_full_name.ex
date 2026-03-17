defmodule IntellectualClub.Knowledge.Changes.SetTagFullName do
  @moduledoc """
  Populates `full_name` for hierarchical knowledge tags.
  """

  use Ash.Resource.Change

  alias IntellectualClub.Knowledge.KnowledgeTag

  @impl true
  def change(changeset, _opts, context) do
    name = Ash.Changeset.get_attribute(changeset, :name)
    parent_id = Ash.Changeset.get_attribute(changeset, :parent_id)

    full_name =
      case parent_id do
        nil ->
          name

        parent_id ->
          opts = [actor: context.actor]

          opts =
            if is_boolean(context.authorize?),
              do: Keyword.put(opts, :authorize?, context.authorize?),
              else: opts

          parent =
            Ash.get!(KnowledgeTag, parent_id, opts)

          parent.full_name <> " / " <> name
      end

    Ash.Changeset.change_attribute(changeset, :full_name, full_name)
  end
end
