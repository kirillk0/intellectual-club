defmodule IntellectualClub.Repo.Migrations.RenameMcpHttpToolType do
  use Ecto.Migration

  def up do
    execute("UPDATE tool_instances SET type = 'mcp-http' WHERE type = 'mcp_http'")
  end

  def down do
    execute("UPDATE tool_instances SET type = 'mcp_http' WHERE type = 'mcp-http'")
  end
end
