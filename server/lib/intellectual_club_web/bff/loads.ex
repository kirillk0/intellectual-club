defmodule IntellectualClubWeb.Bff.Loads do
  @moduledoc """
  Reusable Ash load/select specs for BFF responses.

  These specs intentionally keep `/state` payload queries narrow and avoid
  loading heavyweight fields that are not serialized to the SPA.
  """

  def message_tree do
    [
      steps: [
        :id,
        :sequence,
        :created_at,
        :finished_at,
        :status,
        :response_final,
        :input_tokens,
        :output_tokens,
        :cached_input_tokens,
        :reasoning_tokens,
        :first_token_at,
        :cost,
        items: [
          :id,
          :sequence,
          :created_at,
          :type,
          :tool_call_item_id,
          contents: [
            :id,
            :external_id,
            :sequence,
            :kind,
            :content_text,
            :content_json,
            file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]
          ]
        ]
      ]
    ]
  end

  def message_preview_tree do
    [
      steps: [
        :sequence,
        items: [
          :sequence,
          :type,
          contents: [
            :sequence,
            :kind,
            :content_text
          ]
        ]
      ]
    ]
  end

  def prompt_source_binding do
    [knowledge_block: prompt_source_knowledge_block()]
  end

  def chat_block_binding do
    [knowledge_block: knowledge_block_option()]
  end

  def knowledge_block_option do
    [
      :id,
      :name,
      :version,
      :token_count,
      :image,
      :can_edit,
      :shared_incoming,
      :shared_outgoing
    ]
  end

  def prompt_source_knowledge_block do
    [
      :id,
      :name,
      :version,
      :token_count,
      :content,
      :variables,
      :image,
      :can_edit,
      :shared_incoming,
      :shared_outgoing
    ]
  end

  def bot_option_select do
    [
      :id,
      :name,
      :default_llm_configuration_id,
      :context_soft_limit_percent,
      :supports_file_processing,
      :max_file_size_bytes,
      :created_at,
      :updated_at
    ]
  end

  def bot_option_load do
    [
      :sort_activity_at,
      :image,
      :can_edit,
      :shared_incoming,
      :shared_outgoing,
      compatible_configuration_tags: [:id, :name]
    ]
  end

  def llm_configuration_option_select do
    [
      :id,
      :model_name,
      :note,
      :enabled,
      :context_length,
      :supports_image_input
    ]
  end

  def llm_configuration_option_load do
    [:can_edit, :shared_incoming, :shared_outgoing, tags: [:id, :name]]
  end

  def knowledge_block_option_select do
    [:id, :name, :version, :token_count]
  end

  def knowledge_block_option_load do
    [:image, :can_edit, :shared_incoming, :shared_outgoing]
  end
end
