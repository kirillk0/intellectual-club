defmodule IntellectualClub.Repo.Migrations.AddFirstTokenAtToChatMessageSteps do
  use Ecto.Migration

  def change do
    alter table(:chat_message_steps) do
      add :first_token_at, :utc_datetime_usec
    end
  end
end
