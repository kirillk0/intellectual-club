defmodule IntellectualClub.Repo.Migrations.PreserveDeletedConfigurationHistory do
  @moduledoc """
  Updates resources based on their most recent snapshots.

  Generated with `mix ash_postgres.generate_migrations`, with a historical label backfill.
  """

  use Ecto.Migration

  def up do
    drop constraint(
           :llm_configuration_knowledge_blocks,
           "llm_configuration_knowledge_blocks_llm_configuration_id_fkey"
         )

    alter table(:llm_configuration_knowledge_blocks) do
      modify :llm_configuration_id,
             references(:llm_configurations,
               column: :id,
               name: "llm_configuration_knowledge_blocks_llm_configuration_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :delete_all
             )
    end

    drop constraint(:chats, "chats_llm_configuration_id_fkey")

    alter table(:chats) do
      modify :llm_configuration_id,
             references(:llm_configurations,
               column: :id,
               name: "chats_llm_configuration_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )
    end

    drop constraint(:bots, "bots_default_llm_configuration_id_fkey")

    alter table(:bots) do
      modify :default_llm_configuration_id,
             references(:llm_configurations,
               column: :id,
               name: "bots_default_llm_configuration_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )
    end

    drop constraint(:llm_usage_records, "llm_usage_records_chat_message_step_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_chat_message_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_chat_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_provider_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_llm_configuration_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_configuration_owner_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_usage_user_id_fkey")

    alter table(:llm_usage_records) do
      modify :usage_user_id,
             references(:users,
               column: :id,
               name: "llm_usage_records_usage_user_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )

      modify :configuration_owner_id,
             references(:users,
               column: :id,
               name: "llm_usage_records_configuration_owner_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )

      modify :llm_configuration_id,
             references(:llm_configurations,
               column: :id,
               name: "llm_usage_records_llm_configuration_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )

      modify :provider_id,
             references(:llm_providers,
               column: :id,
               name: "llm_usage_records_provider_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )

      modify :chat_id,
             references(:chats,
               column: :id,
               name: "llm_usage_records_chat_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )

      modify :chat_message_id,
             references(:chat_messages,
               column: :id,
               name: "llm_usage_records_chat_message_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )

      modify :chat_message_step_id,
             references(:chat_message_steps,
               column: :id,
               name: "llm_usage_records_chat_message_step_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )
    end

    drop constraint(:chat_messages, "chat_messages_llm_configuration_id_fkey")

    alter table(:chat_messages) do
      add :llm_configuration_label_snapshot, :text

      modify :llm_configuration_id,
             references(:llm_configurations,
               column: :id,
               name: "chat_messages_llm_configuration_id_fkey",
               type: :bigint,
               prefix: "public",
               on_delete: :nilify_all
             )
    end

    # Prefer the earliest immutable billing label, including deleted configurations.
    # Copies without billing records fall back to the currently linked configuration.
    execute("""
    UPDATE chat_messages AS message
    SET llm_configuration_label_snapshot = historical.label
    FROM (
      SELECT DISTINCT ON (chat_message_id)
        chat_message_id, llm_configuration_label_snapshot AS label
      FROM llm_usage_records
      WHERE chat_message_id IS NOT NULL
      ORDER BY chat_message_id, occurred_at, step_sequence, id
    ) AS historical
    WHERE message.id = historical.chat_message_id
      AND message.role = 'assistant'
      AND message.llm_configuration_label_snapshot IS NULL
    """)

    execute("""
    UPDATE chat_messages AS message
    SET llm_configuration_label_snapshot = CASE
      WHEN btrim(coalesce(configuration.note, '')) = '' THEN configuration.model_name
      ELSE configuration.model_name || ' (' || btrim(configuration.note) || ')'
    END
    FROM llm_configurations AS configuration
    WHERE message.llm_configuration_id = configuration.id
      AND message.role = 'assistant'
      AND message.llm_configuration_label_snapshot IS NULL
    """)
  end

  def down do
    drop constraint(:chat_messages, "chat_messages_llm_configuration_id_fkey")

    alter table(:chat_messages) do
      modify :llm_configuration_id,
             references(:llm_configurations,
               column: :id,
               name: "chat_messages_llm_configuration_id_fkey",
               type: :bigint,
               prefix: "public"
             )

      remove :llm_configuration_label_snapshot
    end

    drop constraint(:llm_usage_records, "llm_usage_records_usage_user_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_configuration_owner_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_llm_configuration_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_provider_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_chat_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_chat_message_id_fkey")

    drop constraint(:llm_usage_records, "llm_usage_records_chat_message_step_id_fkey")

    alter table(:llm_usage_records) do
      modify :chat_message_step_id,
             references(:chat_message_steps,
               column: :id,
               name: "llm_usage_records_chat_message_step_id_fkey",
               type: :bigint,
               prefix: "public"
             )

      modify :chat_message_id,
             references(:chat_messages,
               column: :id,
               name: "llm_usage_records_chat_message_id_fkey",
               type: :bigint,
               prefix: "public"
             )

      modify :chat_id,
             references(:chats,
               column: :id,
               name: "llm_usage_records_chat_id_fkey",
               type: :bigint,
               prefix: "public"
             )

      modify :provider_id,
             references(:llm_providers,
               column: :id,
               name: "llm_usage_records_provider_id_fkey",
               type: :bigint,
               prefix: "public"
             )

      modify :llm_configuration_id,
             references(:llm_configurations,
               column: :id,
               name: "llm_usage_records_llm_configuration_id_fkey",
               type: :bigint,
               prefix: "public"
             )

      modify :configuration_owner_id,
             references(:users,
               column: :id,
               name: "llm_usage_records_configuration_owner_id_fkey",
               type: :bigint,
               prefix: "public"
             )

      modify :usage_user_id,
             references(:users,
               column: :id,
               name: "llm_usage_records_usage_user_id_fkey",
               type: :bigint,
               prefix: "public"
             )
    end

    drop constraint(:bots, "bots_default_llm_configuration_id_fkey")

    alter table(:bots) do
      modify :default_llm_configuration_id,
             references(:llm_configurations,
               column: :id,
               name: "bots_default_llm_configuration_id_fkey",
               type: :bigint,
               prefix: "public"
             )
    end

    drop constraint(:chats, "chats_llm_configuration_id_fkey")

    alter table(:chats) do
      modify :llm_configuration_id,
             references(:llm_configurations,
               column: :id,
               name: "chats_llm_configuration_id_fkey",
               type: :bigint,
               prefix: "public"
             )
    end

    drop constraint(
           :llm_configuration_knowledge_blocks,
           "llm_configuration_knowledge_blocks_llm_configuration_id_fkey"
         )

    alter table(:llm_configuration_knowledge_blocks) do
      modify :llm_configuration_id,
             references(:llm_configurations,
               column: :id,
               name: "llm_configuration_knowledge_blocks_llm_configuration_id_fkey",
               type: :bigint,
               prefix: "public"
             )
    end
  end
end
