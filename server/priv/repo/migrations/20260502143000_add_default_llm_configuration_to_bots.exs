defmodule IntellectualClub.Repo.Migrations.AddDefaultLlmConfigurationToBots do
  @moduledoc """
  Adds an optional default LLM configuration for bots.
  """

  use Ecto.Migration

  def change do
    alter table(:bots) do
      add :default_llm_configuration_id,
          references(:llm_configurations,
            column: :id,
            name: "bots_default_llm_configuration_id_fkey",
            type: :bigint
          ),
          null: true
    end

    create index(:bots, [:default_llm_configuration_id],
             name: "bots_default_llm_configuration_id_index"
           )
  end
end
