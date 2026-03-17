defmodule IntellectualClub.Repo.Migrations.BaselineSchema do
  @moduledoc """
  Baseline schema migration for the v2 prototype.

  This migration intentionally consolidates previous iterative migrations
  into a single manual Ecto migration for clean database bootstrapping.
  """

  use Ecto.Migration

  def up do
    create table(:users, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :is_admin, :boolean, null: false
      add :hashed_password, :text, null: false
      add :username, :text, null: false
      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:users, [:username], name: "users_unique_username_index")

    create table(:tokens, primary_key: false) do
      add :jti, :text, null: false, primary_key: true
      add :subject, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :purpose, :text, null: false
      add :extra_data, :map
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:knowledge_tags, primary_key: false) do
      add :parent_id,
          references(:knowledge_tags,
            column: :id,
            name: "knowledge_tags_parent_id_fkey",
            type: :bigint
          )

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :full_name, :text, null: false
      add :name, :text, null: false

      add :owner_id,
          references(:users, column: :id, name: "knowledge_tags_owner_id_fkey", type: :bigint),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:knowledge_tags, [:owner_id, :full_name],
             name: "knowledge_tags_unique_full_name_index"
           )

    create table(:files, primary_key: false) do
      add :created_at, :utc_datetime_usec, null: false
      add :external_id, :uuid, null: false
      add :storage_backend, :text, null: false
      add :mime_type, :text, null: false
      add :size_bytes, :bigint, null: false
      add :filename, :text, null: false
      add :sha256, :text, null: false
      add :id, :bigserial, null: false, primary_key: true
    end

    create index(:files, [:sha256], name: "files_sha256_index")
    create unique_index(:files, [:external_id], name: "files_external_id_index")

    create table(:file_payloads, primary_key: false) do
      add :payload, :binary, null: false
      add :sha256, :text, null: false, primary_key: true
    end

    create table(:knowledge_blocks, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :variables, :map, null: false, default: %{}
      add :token_count, :bigint, null: false
      add :content, :text, null: false
      add :type, :text, null: false
      add :version, :text, null: false
      add :name, :text, null: false
      add :external_id, :uuid, null: false

      add :image_file_id,
          references(:files,
            column: :id,
            name: "knowledge_blocks_image_file_id_fkey",
            type: :bigint
          )

      add :owner_id,
          references(:users, column: :id, name: "knowledge_blocks_owner_id_fkey", type: :bigint),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:knowledge_blocks, [:external_id],
             name: "knowledge_blocks_unique_external_id_index"
           )

    create index(:knowledge_blocks, [:image_file_id],
             name: "knowledge_blocks_image_file_id_index"
           )

    create table(:knowledge_block_tags, primary_key: false) do
      add :knowledge_tag_id,
          references(:knowledge_tags,
            column: :id,
            name: "knowledge_block_tags_knowledge_tag_id_fkey",
            type: :bigint
          ),
          null: false

      add :knowledge_block_id,
          references(:knowledge_blocks,
            column: :id,
            name: "knowledge_block_tags_knowledge_block_id_fkey",
            type: :bigint
          ),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "knowledge_block_tags_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:knowledge_block_tags, [:knowledge_block_id, :knowledge_tag_id],
             name: "knowledge_block_tags_unique_pair_index"
           )

    create table(:bots, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :history_mode, :text, null: false
      add :context_soft_limit_percent, :bigint, null: false
      add :max_tool_rounds, :bigint, null: false
      add :variables, :map, null: false, default: %{}
      add :first_messages, {:array, :text}, null: false, default: []
      add :name, :text, null: false
      add :external_id, :uuid, null: false
      add :supports_file_processing, :boolean, null: false, default: false
      add :max_file_size_bytes, :bigint, null: false, default: 500 * 1024 * 1024

      add :image_file_id,
          references(:files, column: :id, name: "bots_image_file_id_fkey", type: :bigint)

      add :owner_id,
          references(:users, column: :id, name: "bots_owner_id_fkey", type: :bigint),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:bots, [:external_id], name: "bots_unique_external_id_index")
    create index(:bots, [:image_file_id], name: "bots_image_file_id_index")

    create table(:bot_knowledge_blocks, primary_key: false) do
      add :knowledge_block_id,
          references(:knowledge_blocks,
            column: :id,
            name: "bot_knowledge_blocks_knowledge_block_id_fkey",
            type: :bigint
          ),
          null: false

      add :bot_id,
          references(:bots, column: :id, name: "bot_knowledge_blocks_bot_id_fkey", type: :bigint),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :sequence, :bigint, null: false
      add :enabled, :boolean, null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "bot_knowledge_blocks_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:bot_knowledge_blocks, [:bot_id, :knowledge_block_id],
             name: "bot_knowledge_blocks_unique_pair_index"
           )

    create index(:bot_knowledge_blocks, [:bot_id, :enabled],
             name: "bot_knowledge_blocks_bot_enabled_index"
           )

    create table(:llm_providers, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :api_key, :text
      add :oauth_refresh_token, :text
      add :base_url, :text
      add :auth_method, :text, null: false, default: "api_key"
      add :type, :text, null: false
      add :name, :text, null: false

      add :owner_id,
          references(:users, column: :id, name: "llm_providers_owner_id_fkey", type: :bigint),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create table(:llm_configurations, primary_key: false) do
      add :provider_id,
          references(:llm_providers,
            column: :id,
            name: "llm_configurations_provider_id_fkey",
            type: :bigint
          ),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :supports_image_input, :boolean, null: false
      add :supports_cache_control, :boolean, null: false
      add :context_length, :bigint
      add :timeout_seconds, :bigint, null: false
      add :enabled, :boolean, null: false
      add :parameters, :map, null: false, default: %{}
      add :note, :text
      add :model_name, :text, null: false
      add :external_id, :uuid, null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "llm_configurations_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:llm_configurations, [:external_id],
             name: "llm_configurations_unique_external_id_index"
           )

    create table(:llm_configuration_knowledge_blocks, primary_key: false) do
      add :knowledge_block_id,
          references(:knowledge_blocks,
            column: :id,
            name: "llm_configuration_knowledge_blocks_knowledge_block_id_fkey",
            type: :bigint
          ),
          null: false

      add :llm_configuration_id,
          references(:llm_configurations,
            column: :id,
            name: "llm_configuration_knowledge_blocks_llm_configuration_id_fkey",
            type: :bigint
          ),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :sequence, :bigint, null: false
      add :enabled, :boolean, null: false
      add :selection, :text, null: false, default: "bottom"

      add :owner_id,
          references(:users,
            column: :id,
            name: "llm_configuration_knowledge_blocks_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(
             :llm_configuration_knowledge_blocks,
             [:llm_configuration_id, :knowledge_block_id],
             name: "llm_configuration_knowledge_blocks_unique_pair_index"
           )

    create index(
             :llm_configuration_knowledge_blocks,
             [:llm_configuration_id, :enabled],
             name: "llm_configuration_knowledge_blocks_config_enabled_index"
           )

    create table(:llm_configuration_tags) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :name, :text, null: false

      timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
    end

    create unique_index(:llm_configuration_tags, [:owner_id, :name])

    create table(:user_groups) do
      add :name, :text, null: false

      timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
    end

    create unique_index(:user_groups, [:name])

    create table(:user_group_memberships) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :user_group_id, references(:user_groups, on_delete: :delete_all), null: false

      timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
    end

    create index(:user_group_memberships, [:user_id])
    create index(:user_group_memberships, [:user_group_id])
    create unique_index(:user_group_memberships, [:user_id, :user_group_id])

    create table(:llm_configuration_tag_bindings) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false

      add :llm_configuration_id, references(:llm_configurations, on_delete: :delete_all),
        null: false

      add :llm_configuration_tag_id, references(:llm_configuration_tags, on_delete: :delete_all),
        null: false

      timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
    end

    create index(:llm_configuration_tag_bindings, [:owner_id])
    create index(:llm_configuration_tag_bindings, [:llm_configuration_id])
    create index(:llm_configuration_tag_bindings, [:llm_configuration_tag_id])

    create unique_index(:llm_configuration_tag_bindings, [
             :llm_configuration_id,
             :llm_configuration_tag_id
           ])

    create table(:bot_compatible_configuration_tags) do
      add :owner_id, references(:users, on_delete: :delete_all), null: false
      add :bot_id, references(:bots, on_delete: :delete_all), null: false

      add :llm_configuration_tag_id, references(:llm_configuration_tags, on_delete: :delete_all),
        null: false

      timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
    end

    create index(:bot_compatible_configuration_tags, [:owner_id])
    create index(:bot_compatible_configuration_tags, [:bot_id])
    create index(:bot_compatible_configuration_tags, [:llm_configuration_tag_id])
    create unique_index(:bot_compatible_configuration_tags, [:bot_id, :llm_configuration_tag_id])

    create table(:bot_shares) do
      add :bot_id, references(:bots, on_delete: :delete_all), null: false
      add :user_group_id, references(:user_groups, on_delete: :delete_all), null: false

      timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
    end

    create index(:bot_shares, [:bot_id])
    create index(:bot_shares, [:user_group_id])
    create unique_index(:bot_shares, [:bot_id, :user_group_id])

    create table(:llm_configuration_shares) do
      add :llm_configuration_id, references(:llm_configurations, on_delete: :delete_all),
        null: false

      add :user_group_id, references(:user_groups, on_delete: :delete_all), null: false

      timestamps(inserted_at: :created_at, updated_at: :updated_at, type: :utc_datetime_usec)
    end

    create index(:llm_configuration_shares, [:llm_configuration_id])
    create index(:llm_configuration_shares, [:user_group_id])
    create unique_index(:llm_configuration_shares, [:llm_configuration_id, :user_group_id])

    create table(:tool_instances, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :max_output_tokens, :bigint, null: false, default: 20_000
      add :secrets, :map, null: false, default: %{}
      add :config, :map, null: false, default: %{}
      add :name, :text, null: false
      add :type, :text, null: false
      add :last_discovered_at, :utc_datetime_usec
      add :last_discovery_error, :text, null: false, default: ""

      add :owner_id,
          references(:users,
            column: :id,
            name: "tool_instances_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create index(:tool_instances, [:owner_id], name: "tool_instances_owner_id_index")

    create table(:tool_functions, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :enabled, :boolean, null: false, default: true
      add :parameters_schema, :map, null: false, default: %{}
      add :description, :text, null: false, default: ""
      add :name, :text, null: false
      add :discovered_at, :utc_datetime_usec, null: false

      add :tool_instance_id,
          references(:tool_instances,
            column: :id,
            name: "tool_functions_tool_instance_id_fkey",
            type: :bigint
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "tool_functions_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:tool_functions, [:tool_instance_id, :name],
             name: "tool_functions_unique_instance_name_index"
           )

    create index(:tool_functions, [:owner_id], name: "tool_functions_owner_id_index")

    create table(:bot_tool_bindings, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :sequence, :bigint, null: false, default: 0
      add :enabled, :boolean, null: false, default: true
      add :sharing_mode, :text, null: false, default: "shared"
      add :alias, :text, null: false

      add :tool_instance_id,
          references(:tool_instances,
            column: :id,
            name: "bot_tool_bindings_tool_instance_id_fkey",
            type: :bigint
          ),
          null: false

      add :bot_id,
          references(:bots, column: :id, name: "bot_tool_bindings_bot_id_fkey", type: :bigint),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "bot_tool_bindings_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:bot_tool_bindings, [:bot_id, :alias],
             name: "bot_tool_bindings_unique_bot_alias_index"
           )

    create index(:bot_tool_bindings, [:owner_id], name: "bot_tool_bindings_owner_id_index")

    create table(:bot_user_tool_bindings, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :sequence, :bigint, null: false, default: 0
      add :enabled, :boolean, null: false, default: true
      add :alias, :text, null: false

      add :tool_instance_id,
          references(:tool_instances,
            column: :id,
            name: "bot_user_tool_bindings_tool_instance_id_fkey",
            type: :bigint
          ),
          null: false

      add :bot_id,
          references(:bots,
            column: :id,
            name: "bot_user_tool_bindings_bot_id_fkey",
            type: :bigint
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "bot_user_tool_bindings_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:bot_user_tool_bindings, [:owner_id, :bot_id, :alias],
             name: "bot_user_tool_bindings_unique_owner_bot_alias_index"
           )

    create table(:outlet_pairing_requests, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :user_code, :text, null: false
      add :device_code_hash, :text, null: false
      add :runner_kind, :text, null: false, default: ""
      add :requested_name, :text, null: false, default: ""
      add :created_ip, :text
      add :created_user_agent, :text, null: false, default: ""
      add :metadata, :map, null: false, default: %{}
      add :status, :text, null: false, default: "pending"
      add :expires_at, :utc_datetime_usec, null: false
      add :approved_at, :utc_datetime_usec

      add :approved_by_id,
          references(:users,
            column: :id,
            name: "outlet_pairing_requests_approved_by_id_fkey",
            type: :bigint
          )

      add :tool_instance_id,
          references(:tool_instances,
            column: :id,
            name: "outlet_pairing_requests_tool_instance_id_fkey",
            type: :bigint
          )

      add :delivered_at, :utc_datetime_usec
      add :consumed_at, :utc_datetime_usec
      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:outlet_pairing_requests, [:user_code],
             name: "outlet_pairing_requests_user_code_index"
           )

    create index(:outlet_pairing_requests, [:device_code_hash],
             name: "outlet_pairing_requests_device_code_hash_index"
           )

    create index(:outlet_pairing_requests, [:status, :expires_at, :created_at],
             name: "outlet_pairing_requests_status_expires_created_index"
           )

    create table(:chats, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :title, :text, null: false

      add :owner_id,
          references(:users, column: :id, name: "chats_owner_id_fkey", type: :bigint),
          null: false

      add :bot_id, references(:bots, column: :id, name: "chats_bot_id_fkey", type: :bigint)

      add :llm_configuration_id,
          references(:llm_configurations,
            column: :id,
            name: "chats_llm_configuration_id_fkey",
            type: :bigint
          )

      add :note, :text, null: false, default: ""
      add :variables, :map, null: false, default: %{}
      add :id, :bigserial, null: false, primary_key: true
    end

    create table(:chat_messages, primary_key: false) do
      add :chat_id,
          references(:chats, column: :id, name: "chat_messages_chat_id_fkey", type: :bigint),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :token_count, :bigint, null: false
      add :error_detail, :text
      add :status, :text, null: false
      add :role, :text, null: false

      add :owner_id,
          references(:users, column: :id, name: "chat_messages_owner_id_fkey", type: :bigint),
          null: false

      add :llm_configuration_id,
          references(:llm_configurations,
            column: :id,
            name: "chat_messages_llm_configuration_id_fkey",
            type: :bigint
          )

      add :parent_id,
          references(:chat_messages,
            column: :id,
            name: "chat_messages_parent_id_fkey",
            type: :bigint
          )

      add :id, :bigserial, null: false, primary_key: true
    end

    alter table(:chats) do
      add :last_message_id,
          references(:chat_messages,
            column: :id,
            name: "chats_last_message_id_fkey",
            type: :bigint
          )
    end

    create table(:chat_message_steps, primary_key: false) do
      add :chat_message_id,
          references(:chat_messages,
            column: :id,
            name: "chat_message_steps_chat_message_id_fkey",
            type: :bigint
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "chat_message_steps_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :status, :text, null: false, default: "done"
      add :cost, :float
      add :output_tokens, :bigint
      add :input_tokens, :bigint
      add :cached_input_tokens, :bigint
      add :reasoning_tokens, :bigint
      add :response_final, :boolean, null: false, default: false
      add :raw_response, :map
      add :raw_request, :map, null: false, default: %{}
      add :sequence, :bigint, null: false
      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:chat_message_steps, [:chat_message_id, :sequence],
             name: "chat_message_steps_unique_chat_message_sequence_index"
           )

    create table(:chat_message_items, primary_key: false) do
      add :chat_message_step_id,
          references(:chat_message_steps,
            column: :id,
            name: "chat_message_items_chat_message_step_id_fkey",
            type: :bigint
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "chat_message_items_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :type, :text, null: false
      add :sequence, :bigint, null: false
      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:chat_message_items, [:chat_message_step_id, :sequence],
             name: "chat_message_items_unique_step_sequence_index"
           )

    create table(:chat_message_contents, primary_key: false) do
      add :chat_message_item_id,
          references(:chat_message_items,
            column: :id,
            name: "chat_message_contents_chat_message_item_id_fkey",
            type: :bigint
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "chat_message_contents_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :external_id, :uuid, null: false
      add :content_json, :map
      add :content_text, :text, null: false, default: ""
      add :kind, :text, null: false
      add :sequence, :bigint, null: false

      add :file_id,
          references(:files,
            column: :id,
            name: "chat_message_contents_file_id_fkey",
            type: :bigint
          )

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:chat_message_contents, [:chat_message_item_id, :sequence],
             name: "chat_message_contents_unique_item_sequence_index"
           )

    create unique_index(:chat_message_contents, [:external_id],
             name: "chat_message_contents_external_id_index"
           )

    create index(:chat_message_contents, [:file_id], name: "chat_message_contents_file_id_index")

    create table(:chat_knowledge_blocks, primary_key: false) do
      add :knowledge_block_id,
          references(:knowledge_blocks,
            column: :id,
            name: "chat_knowledge_blocks_knowledge_block_id_fkey",
            type: :bigint
          ),
          null: false

      add :chat_id,
          references(:chats,
            column: :id,
            name: "chat_knowledge_blocks_chat_id_fkey",
            type: :bigint
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "chat_knowledge_blocks_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :sequence, :bigint, null: false
      add :enabled, :boolean, null: false
      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:chat_knowledge_blocks, [:chat_id, :knowledge_block_id],
             name: "chat_knowledge_blocks_unique_pair_index"
           )

    create index(:chat_knowledge_blocks, [:chat_id, :enabled],
             name: "chat_knowledge_blocks_chat_enabled_index"
           )

    create table(:user_knowledge_blocks, primary_key: false) do
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :sequence, :bigint, null: false, default: 0
      add :enabled, :boolean, null: false, default: true

      add :knowledge_block_id,
          references(:knowledge_blocks,
            column: :id,
            name: "user_knowledge_blocks_knowledge_block_id_fkey",
            type: :bigint
          ),
          null: false

      add :owner_id,
          references(:users,
            column: :id,
            name: "user_knowledge_blocks_owner_id_fkey",
            type: :bigint
          ),
          null: false

      add :id, :bigserial, null: false, primary_key: true
    end

    create unique_index(:user_knowledge_blocks, [:owner_id, :knowledge_block_id],
             name: "user_knowledge_blocks_unique_pair_index"
           )

    create index(:user_knowledge_blocks, [:owner_id],
             name: "user_knowledge_blocks_owner_id_index"
           )

    create index(:user_knowledge_blocks, [:owner_id, :enabled],
             name: "user_knowledge_blocks_owner_enabled_index"
           )

    create index(:chats, [:owner_id, :updated_at, :id], name: "chats_owner_updated_id_index")

    create index(:chat_messages, [:chat_id, :created_at, :id],
             name: "chat_messages_chat_created_id_index"
           )

    create index(:chat_messages, [:chat_id, :parent_id],
             name: "chat_messages_chat_parent_id_index"
           )

    create index(:chat_messages, [:owner_id, :chat_id], name: "chat_messages_owner_chat_id_index")

    if sqlite?() do
      create_sqlite_chat_message_contents_fts()
    end

    if postgres?() do
      create_postgres_search_support()
    end
  end

  def down do
    raise """
    Baseline migration is irreversible.
    Recreate the database with `mix ecto.drop && mix ecto.setup`.
    """
  end

  defp create_sqlite_chat_message_contents_fts do
    execute("""
    CREATE VIRTUAL TABLE chat_message_contents_fts
    USING fts5(
      content_text,
      content='chat_message_contents',
      content_rowid='id',
      tokenize='unicode61'
    )
    """)

    execute("""
    INSERT INTO chat_message_contents_fts(rowid, content_text)
    SELECT id, content_text
    FROM chat_message_contents
    WHERE kind = 'text'
    """)

    execute("""
    CREATE TRIGGER chat_message_contents_fts_insert
    AFTER INSERT ON chat_message_contents
    WHEN new.kind = 'text'
    BEGIN
      INSERT INTO chat_message_contents_fts(rowid, content_text)
      VALUES (new.id, new.content_text);
    END
    """)

    execute("""
    CREATE TRIGGER chat_message_contents_fts_delete
    AFTER DELETE ON chat_message_contents
    WHEN old.kind = 'text'
    BEGIN
      INSERT INTO chat_message_contents_fts(chat_message_contents_fts, rowid, content_text)
      VALUES ('delete', old.id, old.content_text);
    END
    """)

    execute("""
    CREATE TRIGGER chat_message_contents_fts_update
    AFTER UPDATE OF kind, content_text ON chat_message_contents
    BEGIN
      INSERT INTO chat_message_contents_fts(chat_message_contents_fts, rowid, content_text)
      SELECT 'delete', old.id, old.content_text
      WHERE old.kind = 'text';

      INSERT INTO chat_message_contents_fts(rowid, content_text)
      SELECT new.id, new.content_text
      WHERE new.kind = 'text';
    END
    """)
  end

  defp create_postgres_search_support do
    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_or(left BOOLEAN, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE)
    AS $$ SELECT COALESCE(NULLIF($1, FALSE), $2) $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_or(left ANYCOMPATIBLE, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE)
    AS $$ SELECT COALESCE($1, $2) $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_and(left BOOLEAN, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE) AS $$
      SELECT CASE
        WHEN $1 IS TRUE THEN $2
        ELSE $1
      END $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_elixir_and(left ANYCOMPATIBLE, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE) AS $$
      SELECT CASE
        WHEN $1 IS NOT NULL THEN $2
        ELSE $1
      END $$
    LANGUAGE SQL
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_trim_whitespace(arr text[])
    RETURNS text[] AS $$
    DECLARE
        start_index INT = 1;
        end_index INT = array_length(arr, 1);
    BEGIN
        WHILE start_index <= end_index AND arr[start_index] = '' LOOP
            start_index := start_index + 1;
        END LOOP;

        WHILE end_index >= start_index AND arr[end_index] = '' LOOP
            end_index := end_index - 1;
        END LOOP;

        IF start_index > end_index THEN
            RETURN ARRAY[]::text[];
        ELSE
            RETURN arr[start_index : end_index];
        END IF;
    END; $$
    LANGUAGE plpgsql
    SET search_path = ''
    IMMUTABLE;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_raise_error(json_data jsonb)
    RETURNS BOOLEAN AS $$
    BEGIN
        RAISE EXCEPTION 'ash_error: %', json_data::text;
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    STABLE
    SET search_path = '';
    """)

    execute("""
    CREATE OR REPLACE FUNCTION ash_raise_error(json_data jsonb, type_signal ANYCOMPATIBLE)
    RETURNS ANYCOMPATIBLE AS $$
    BEGIN
        RAISE EXCEPTION 'ash_error: %', json_data::text;
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    STABLE
    SET search_path = '';
    """)

    execute("""
    CREATE OR REPLACE FUNCTION uuid_generate_v7()
    RETURNS UUID
    AS $$
    DECLARE
      timestamp    TIMESTAMPTZ;
      microseconds INT;
    BEGIN
      timestamp    = clock_timestamp();
      microseconds = (cast(extract(microseconds FROM timestamp)::INT - (floor(extract(milliseconds FROM timestamp))::INT * 1000) AS DOUBLE PRECISION) * 4.096)::INT;

      RETURN encode(
        set_byte(
          set_byte(
            overlay(uuid_send(gen_random_uuid()) placing substring(int8send(floor(extract(epoch FROM timestamp) * 1000)::BIGINT) FROM 3) FROM 1 FOR 6
          ),
          6, (b'0111' || (microseconds >> 8)::bit(4))::bit(8)::int
        ),
        7, microseconds::bit(8)::int
      ),
      'hex')::UUID;
    END
    $$
    LANGUAGE PLPGSQL
    SET search_path = ''
    VOLATILE;
    """)

    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute("""
    CREATE INDEX IF NOT EXISTS chat_message_contents_content_text_trgm_index
    ON chat_message_contents
    USING gin (content_text gin_trgm_ops)
    WHERE kind = 'text'
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS chats_note_trgm_index
    ON chats
    USING gin (note gin_trgm_ops)
    WHERE note <> ''
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS bots_name_trgm_index
    ON bots
    USING gin (name gin_trgm_ops)
    """)
  end

  defp sqlite? do
    repo().__adapter__() == Ecto.Adapters.SQLite3
  end

  defp postgres? do
    repo().__adapter__() == Ecto.Adapters.Postgres
  end
end
