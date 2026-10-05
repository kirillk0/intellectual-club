defmodule IntellectualClub.LlmFixtures do
  @moduledoc """
  Fixtures for LLM providers, configurations, their tags and sharing, and usage records.
  """

  import IntellectualClub.Fixtures

  alias IntellectualClub.Llm.{
    LlmConfiguration,
    LlmConfigurationShare,
    LlmConfigurationTag,
    LlmProvider,
    LlmUsageRecord
  }

  @openrouter_base_url "https://openrouter.ai/api/v1"

  @doc """
  Creates an LLM provider. Defaults: a unique `name`, `type: :demo`,
  `auth_method: :api_key`.

  Non-demo providers additionally default to `api_key: "test-key"`, and
  `:openrouter_chat_completion` to the public OpenRouter `base_url`.
  """
  def create_provider!(actor, attrs \\ %{}) do
    attrs = to_attrs(attrs)
    type = Map.get(attrs, :type, :demo)

    defaults =
      %{name: unique_name("Provider"), type: type, auth_method: :api_key}
      |> put_type_defaults(type)

    create!(LlmProvider, Map.merge(defaults, attrs), actor)
  end

  defp put_type_defaults(defaults, :demo), do: defaults

  defp put_type_defaults(defaults, :openrouter_chat_completion) do
    defaults
    |> Map.put(:base_url, @openrouter_base_url)
    |> Map.put(:api_key, "test-key")
  end

  defp put_type_defaults(defaults, _type), do: Map.put(defaults, :api_key, "test-key")

  @doc """
  Creates an LLM configuration.

  The provider is taken from `:provider` (a record) or `:provider_id`; when
  neither is given, a provider is created with `create_provider!/2` from
  `:provider_attrs` (default: a demo provider).

  Defaults: `model_name: "demo-model"`, `note: "cfg"`, `parameters: %{}`,
  `enabled: true`, `timeout_seconds: 30`, `context_length: 2048`,
  `supports_cache_control: false`, `supports_image_input: false`.
  Relationship arguments such as `:tag_bindings` are passed through.
  """
  def create_configuration!(actor, attrs \\ %{}) do
    {provider_opts, attrs} = Map.split(to_attrs(attrs), [:provider, :provider_attrs])

    provider_id =
      case provider_opts do
        %{provider: provider} -> provider.id
        _other -> Map.get(attrs, :provider_id)
      end

    provider_id =
      provider_id ||
        create_provider!(actor, Map.get(provider_opts, :provider_attrs, %{})).id

    defaults = %{
      provider_id: provider_id,
      model_name: "demo-model",
      note: "cfg",
      parameters: %{},
      enabled: true,
      timeout_seconds: 30,
      context_length: 2048,
      supports_cache_control: false,
      supports_image_input: false
    }

    create!(LlmConfiguration, Map.merge(defaults, attrs), actor)
  end

  @doc "Shares `configuration` with `group`."
  def share_configuration!(actor, configuration, group) do
    create!(
      LlmConfigurationShare,
      %{llm_configuration_id: configuration.id, user_group_id: group.id},
      actor
    )
  end

  @doc "Creates an LLM configuration tag. Default: a unique `name`."
  def create_configuration_tag!(actor, attrs \\ %{}) do
    create!(LlmConfigurationTag, merge_attrs(%{name: unique_name("tag")}, attrs), actor)
  end

  @doc """
  Records billed LLM usage of `actor` for the step of `anchor` (`%{chat,
  message, step}`, e.g. from `create_tool_call_anchor!/2`). Defaults: cost
  0.25, 200 input and 100 output tokens, step sequence 1, snapshots of the
  actor and of a configuration labelled "Original paid configuration".
  """
  def create_usage_record!(actor, anchor, attrs \\ %{}) do
    defaults = %{
      usage_user_id: actor.id,
      usage_user_id_snapshot: actor.id,
      usage_username_snapshot: actor.username,
      configuration_owner_id_snapshot: actor.id,
      llm_configuration_id_snapshot: 1,
      llm_configuration_label_snapshot: "Original paid configuration",
      chat_id: anchor.chat.id,
      chat_id_snapshot: anchor.chat.id,
      chat_message_id: anchor.message.id,
      chat_message_id_snapshot: anchor.message.id,
      chat_message_step_id: anchor.step.id,
      chat_message_step_id_snapshot: anchor.step.id,
      step_sequence: 1,
      occurred_at: DateTime.utc_now(),
      cost: 0.25,
      input_tokens: 200,
      output_tokens: 100,
      raw_usage: %{"billed_cost" => 0.25}
    }

    create!(LlmUsageRecord, merge_attrs(defaults, attrs), actor)
  end
end
