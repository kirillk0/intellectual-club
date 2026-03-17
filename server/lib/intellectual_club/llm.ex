defmodule IntellectualClub.Llm do
  @moduledoc """
  LLM configuration domain (Ash).
  """

  use Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(IntellectualClub.Llm.LlmConfiguration)
    resource(IntellectualClub.Llm.LlmConfigurationShare)
    resource(IntellectualClub.Llm.LlmConfigurationKnowledgeBlock)
    resource(IntellectualClub.Llm.LlmConfigurationTag)
    resource(IntellectualClub.Llm.LlmConfigurationTagBinding)
    resource(IntellectualClub.Llm.LlmProvider)
  end

  json_api do
    routes do
      base_route "/llm-providers", IntellectualClub.Llm.LlmProvider do
        index :api_read,
          default_fields: [
            :name,
            :type,
            :auth_method,
            :base_url,
            :credentials_present,
            :can_edit,
            :shared_incoming,
            :shared_outgoing
          ]

        get(:api_read,
          default_fields: [
            :name,
            :type,
            :auth_method,
            :base_url,
            :credentials_present,
            :can_edit,
            :shared_incoming,
            :shared_outgoing
          ]
        )

        post(:create)
        post(:duplicate, route: "/:id/duplicate")
        patch(:update)
        delete(:destroy)
      end

      base_route "/llm-configurations", IntellectualClub.Llm.LlmConfiguration do
        index :read,
          default_fields: [
            :provider_id,
            :model_name,
            :note,
            :enabled,
            :context_length,
            :supports_image_input,
            :can_edit,
            :shared_incoming,
            :shared_outgoing
          ]

        get(:read,
          default_fields: [
            :external_id,
            :provider_id,
            :model_name,
            :note,
            :parameters,
            :enabled,
            :timeout_seconds,
            :context_length,
            :supports_cache_control,
            :supports_image_input,
            :created_at,
            :updated_at,
            :can_edit,
            :shared_incoming,
            :shared_outgoing
          ]
        )

        post(:create)
        post(:duplicate, route: "/:id/duplicate")
        patch(:update)
        delete(:destroy)
      end

      base_route "/llm-configuration-tags", IntellectualClub.Llm.LlmConfigurationTag do
        index :search
        get(:read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end

      base_route "/llm-configuration-tag-bindings",
                 IntellectualClub.Llm.LlmConfigurationTagBinding do
        index :read
        get(:read)
        post(:create)
        delete(:destroy)
      end

      base_route "/llm-configuration-knowledge-blocks",
                 IntellectualClub.Llm.LlmConfigurationKnowledgeBlock do
        index :read
        get(:read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end
    end
  end
end
