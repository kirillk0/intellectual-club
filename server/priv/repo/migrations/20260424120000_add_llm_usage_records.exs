defmodule IntellectualClub.Repo.Migrations.AddLlmUsageRecords do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  def up do
    create table(:llm_usage_records, primary_key: false) do
      add :external_id, :uuid, null: false

      add :usage_user_id, references(:users, on_delete: :nilify_all)
      add :usage_user_id_snapshot, :bigint, null: false
      add :usage_username_snapshot, :text, null: false

      add :configuration_owner_id, references(:users, on_delete: :nilify_all)
      add :configuration_owner_id_snapshot, :bigint, null: false

      add :llm_configuration_id, references(:llm_configurations, on_delete: :nilify_all)
      add :llm_configuration_id_snapshot, :bigint, null: false
      add :llm_configuration_external_id_snapshot, :uuid
      add :llm_configuration_label_snapshot, :text, null: false

      add :provider_id, references(:llm_providers, on_delete: :nilify_all)
      add :provider_id_snapshot, :bigint
      add :provider_name_snapshot, :text
      add :provider_type_snapshot, :text

      add :chat_id, references(:chats, on_delete: :nilify_all)
      add :chat_id_snapshot, :bigint, null: false

      add :chat_message_id, references(:chat_messages, on_delete: :nilify_all)
      add :chat_message_id_snapshot, :bigint, null: false

      add :chat_message_step_id, references(:chat_message_steps, on_delete: :nilify_all)
      add :chat_message_step_id_snapshot, :bigint, null: false
      add :step_sequence, :bigint, null: false

      add :status, :text, null: false, default: "done"
      add :response_final, :boolean, null: false, default: false
      add :occurred_at, :utc_datetime_usec, null: false

      add :input_tokens, :bigint
      add :output_tokens, :bigint
      add :cached_input_tokens, :bigint
      add :reasoning_tokens, :bigint
      add :cost, :float
      add :raw_usage, :map

      timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:llm_usage_records, [:external_id],
             name: "llm_usage_records_unique_external_id_index"
           )

    create unique_index(:llm_usage_records, [:chat_message_step_id_snapshot],
             name: "llm_usage_records_unique_step_snapshot_index"
           )

    create index(:llm_usage_records, [:configuration_owner_id_snapshot, :occurred_at],
             name: "llm_usage_records_owner_occurred_at_index"
           )

    create index(
             :llm_usage_records,
             [
               :configuration_owner_id_snapshot,
               :llm_configuration_external_id_snapshot,
               :occurred_at
             ],
             name: "llm_usage_records_owner_config_occurred_at_index"
           )

    create index(:llm_usage_records, [:usage_user_id_snapshot, :occurred_at],
             name: "llm_usage_records_user_occurred_at_index"
           )

    flush()
    backfill_existing_usage_records()
  end

  def down do
    drop table(:llm_usage_records)
  end

  defp backfill_existing_usage_records do
    now = DateTime.utc_now()
    repo = repo()

    rows =
      repo.all(
        from(s in "chat_message_steps",
          join: m in "chat_messages",
          on: m.id == s.chat_message_id,
          join: c in "llm_configurations",
          on: c.id == m.llm_configuration_id,
          left_join: p in "llm_providers",
          on: p.id == c.provider_id,
          left_join: u in "users",
          on: u.id == s.owner_id,
          where:
            m.role == "assistant" and
              not is_nil(m.llm_configuration_id) and
              (not is_nil(s.input_tokens) or not is_nil(s.output_tokens) or
                 not is_nil(s.cached_input_tokens) or not is_nil(s.reasoning_tokens) or
                 not is_nil(s.cost)),
          select: %{
            usage_user_id: s.owner_id,
            usage_username: u.username,
            configuration_owner_id: c.owner_id,
            llm_configuration_id: c.id,
            llm_configuration_external_id: c.external_id,
            model_name: c.model_name,
            note: c.note,
            provider_id: p.id,
            provider_name: p.name,
            provider_type: p.type,
            chat_id: m.chat_id,
            chat_message_id: m.id,
            chat_message_step_id: s.id,
            step_sequence: s.sequence,
            status: s.status,
            response_final: s.response_final,
            occurred_at:
              fragment("COALESCE(?, ?, ?)", s.finished_at, m.finished_at, s.created_at),
            input_tokens: s.input_tokens,
            output_tokens: s.output_tokens,
            cached_input_tokens: s.cached_input_tokens,
            reasoning_tokens: s.reasoning_tokens,
            cost: s.cost
          }
        )
      )

    entries =
      Enum.map(rows, fn row ->
        label = configuration_label(row.model_name, row.note, row.llm_configuration_id)

        %{
          external_id: Ecto.UUID.generate(),
          usage_user_id: row.usage_user_id,
          usage_user_id_snapshot: row.usage_user_id,
          usage_username_snapshot: row.usage_username || "User ##{row.usage_user_id}",
          configuration_owner_id: row.configuration_owner_id,
          configuration_owner_id_snapshot: row.configuration_owner_id,
          llm_configuration_id: row.llm_configuration_id,
          llm_configuration_id_snapshot: row.llm_configuration_id,
          llm_configuration_external_id_snapshot: row.llm_configuration_external_id,
          llm_configuration_label_snapshot: label,
          provider_id: row.provider_id,
          provider_id_snapshot: row.provider_id,
          provider_name_snapshot: row.provider_name,
          provider_type_snapshot: row.provider_type && to_string(row.provider_type),
          chat_id: row.chat_id,
          chat_id_snapshot: row.chat_id,
          chat_message_id: row.chat_message_id,
          chat_message_id_snapshot: row.chat_message_id,
          chat_message_step_id: row.chat_message_step_id,
          chat_message_step_id_snapshot: row.chat_message_step_id,
          step_sequence: row.step_sequence,
          status: row.status || "done",
          response_final: row.response_final || false,
          occurred_at: row.occurred_at || now,
          input_tokens: row.input_tokens,
          output_tokens: row.output_tokens,
          cached_input_tokens: row.cached_input_tokens,
          reasoning_tokens: row.reasoning_tokens,
          cost: row.cost,
          raw_usage: nil,
          created_at: now,
          updated_at: now
        }
      end)

    entries
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      repo.insert_all("llm_usage_records", chunk,
        on_conflict: :nothing,
        conflict_target: [:chat_message_step_id_snapshot]
      )
    end)
  end

  defp configuration_label(model_name, note, id) do
    model_name =
      case model_name do
        value when is_binary(value) and value != "" -> value
        _ -> "Configuration ##{id}"
      end

    note =
      case note do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    if note == "" do
      model_name
    else
      "#{model_name} (#{note})"
    end
  end
end
