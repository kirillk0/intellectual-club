defmodule IntellectualClub.Repo.Migrations.AddGenerationOperationalIndexes do
  @moduledoc """
  Supports active generation fences and pending notification recovery scans.
  """

  use Ecto.Migration

  def change do
    create index(:chat_messages, [:chat_id, :id],
             name: "chat_messages_active_generation_index",
             where: "status = 'generating'"
           )

    create index(:web_push_generation_events, [:id],
             name: "web_push_generation_events_pending_index",
             where: "suppressed = false AND delivered_count < 0"
           )
  end
end
