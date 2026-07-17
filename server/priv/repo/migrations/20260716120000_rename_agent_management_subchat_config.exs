defmodule IntellectualClub.Repo.Migrations.RenameAgentManagementSubchatConfig do
  use Ecto.Migration

  def up do
    Enum.each(up_statements(), &execute/1)
  end

  def down do
    Enum.each(down_statements(), &execute/1)
  end

  @doc false
  def up_statements do
    [
      rename_config_key_sql("nested_forks_limit", "nested_subchats_limit"),
      rename_config_key_sql("allow_handoff_in_forks", "allow_handoff_in_subchats")
    ]
  end

  @doc false
  def down_statements do
    [
      rename_config_key_sql("nested_subchats_limit", "nested_forks_limit"),
      rename_config_key_sql("allow_handoff_in_subchats", "allow_handoff_in_forks")
    ]
  end

  defp rename_config_key_sql(old_key, new_key) do
    """
    UPDATE tool_instances
    SET config =
      CASE
        WHEN config ? '#{new_key}' THEN config - '#{old_key}'
        ELSE (config - '#{old_key}') || jsonb_build_object('#{new_key}', config -> '#{old_key}')
      END
    WHERE type = 'native-agent-management'
      AND config ? '#{old_key}'
    """
  end
end
