defmodule IntellectualClub.Repo.Migrations.CascadeQueuedSteerTargets do
  @moduledoc """
  Uses cascade semantics for queued steer targets so deleting a canonical
  assistant cannot violate the queued-message kind constraint.
  """

  use Ecto.Migration

  def up do
    drop constraint(
           :chat_queued_messages,
           "chat_queued_messages_target_generation_message_id_fkey"
         )

    alter table(:chat_queued_messages) do
      modify :target_generation_message_id,
             references(:chat_messages,
               column: :id,
               name: "chat_queued_messages_target_generation_message_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :delete_all
             )
    end
  end

  def down do
    drop constraint(
           :chat_queued_messages,
           "chat_queued_messages_target_generation_message_id_fkey"
         )

    alter table(:chat_queued_messages) do
      modify :target_generation_message_id,
             references(:chat_messages,
               column: :id,
               name: "chat_queued_messages_target_generation_message_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )
    end
  end
end
