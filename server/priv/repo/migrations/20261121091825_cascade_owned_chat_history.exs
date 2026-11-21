defmodule IntellectualClub.Repo.Migrations.CascadeOwnedChatHistory do
  @moduledoc """
  Delegate trace deletion to PostgreSQL without cascading across owners.

  All trace owner IDs are non-null. A legacy ownership mismatch therefore
  fails FK validation and rolls back this migration rather than silently
  making another owner's history deletable. The request-file binding has no
  independent owner; it belongs to its step.
  """

  use Ecto.Migration

  @owned_edges [
    {:chat_messages, :chat_id, :chats},
    {:chat_message_steps, :chat_message_id, :chat_messages},
    {:chat_message_items, :chat_message_step_id, :chat_message_steps},
    {:chat_message_contents, :chat_message_item_id, :chat_message_items}
  ]
  @request_file_edge {:chat_message_step_request_files, :chat_message_step_id,
                      :chat_message_steps}

  def up do
    for {_, _, parent} <- @owned_edges do
      create unique_index(parent, [:id, :owner_id], name: "#{parent}_id_owner_id_index")
    end

    for edge <- @owned_edges do
      replace_fk(edge, ", owner_id", " ON DELETE CASCADE DEFERRABLE INITIALLY IMMEDIATE")
    end

    replace_fk(@request_file_edge, "", " ON DELETE CASCADE")
  end

  def down do
    for edge <- [@request_file_edge | @owned_edges], do: replace_fk(edge, "", "")

    for {_, _, parent} <- @owned_edges do
      drop index(parent, [:id, :owner_id], name: "#{parent}_id_owner_id_index")
    end
  end

  # Only replace the constraints. Altering the column type would also affect
  # independent triggers on the trace tables, even though its type is unchanged.
  defp replace_fk({child, fk, parent}, owner_column, options) do
    name = "#{child}_#{fk}_fkey"

    execute("""
    ALTER TABLE public.#{child} DROP CONSTRAINT #{name},
      ADD CONSTRAINT #{name} FOREIGN KEY (#{fk}#{owner_column})
      REFERENCES public.#{parent} (id#{owner_column})#{options}
    """)
  end
end
