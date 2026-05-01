defmodule IntellectualClub.Repo.Migrations.DropUniqueOwnerAliasFromToolInstances do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:tool_instances, [:owner_id, :alias],
                     name: "tool_instances_unique_owner_alias_index"
                   )
  end

  def down do
    create unique_index(:tool_instances, [:owner_id, :alias],
             name: "tool_instances_unique_owner_alias_index"
           )
  end
end
