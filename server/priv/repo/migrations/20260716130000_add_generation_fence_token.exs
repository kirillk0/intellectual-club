defmodule IntellectualClub.Repo.Migrations.AddGenerationFenceToken do
  use Ecto.Migration

  def change do
    alter table(:chat_messages) do
      add(:generation_fence_token, :uuid)
    end
  end
end
