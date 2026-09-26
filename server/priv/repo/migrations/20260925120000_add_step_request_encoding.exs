defmodule IntellectualClub.Repo.Migrations.AddStepRequestEncoding do
  @moduledoc """
  Adds full/patch metadata without rewriting any historical request.
  """

  use Ecto.Migration

  def up do
    alter table(:chat_message_steps) do
      add :request_mode, :text, null: false, default: "full"
      add :request_patch, {:array, :map}
      add :request_hash, :text
      add :request_base_hash, :text
      add :request_base_sequence, :bigint
      add :request_checkpoint_distance, :bigint, null: false, default: 0
    end
  end

  def down do
    # Dropping patch metadata would silently discard logical requests. Rollback
    # requires explicit, verified expansion to full requests beforehand.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM chat_message_steps WHERE request_mode <> 'full') THEN
        RAISE EXCEPTION 'Expand step request patches to full encodings before rollback';
      END IF;
    END $$;
    """)

    alter table(:chat_message_steps) do
      remove :request_checkpoint_distance
      remove :request_base_sequence
      remove :request_base_hash
      remove :request_hash
      remove :request_patch
      remove :request_mode
    end
  end
end
