defmodule IntellectualClubWeb.Bff.LlmUsageControllerTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationShare
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Llm.LlmUsageRecord

  test "GET /api/bff/llm-usage returns owner-visible usage by configuration and user", %{
    conn: conn
  } do
    %{user: owner, password: owner_password} = user_fixture()
    %{user: recipient, password: recipient_password} = user_fixture()
    %{user: other_user} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    provider = create_provider!(owner, "Usage provider")
    configuration = create_configuration!(owner, provider, "usage-model")
    share_configuration!(owner, configuration, group)

    create_usage_record!(%{
      usage_user: recipient,
      configuration_owner: owner,
      configuration: configuration,
      provider: provider,
      chat_id: 101,
      message_id: 201,
      step_id: 301,
      step_sequence: 1,
      cost: 0.01
    })

    create_usage_record!(%{
      usage_user: recipient,
      configuration_owner: owner,
      configuration: configuration,
      provider: provider,
      chat_id: 101,
      message_id: 201,
      step_id: 302,
      step_sequence: 2,
      cost: 0.02
    })

    create_usage_record!(%{
      usage_user: other_user,
      configuration_owner: owner,
      configuration: configuration,
      provider: provider,
      chat_id: 102,
      message_id: 202,
      step_id: 303,
      step_sequence: 1,
      cost: 0.03
    })

    owner_payload =
      conn
      |> sign_in_conn(owner.username, owner_password)
      |> get("/api/bff/llm-usage?from=2026-04-24&to=2026-04-24")
      |> json_response(200)

    assert Enum.map(owner_payload["users"], & &1["username"]) |> Enum.sort() ==
             Enum.sort([recipient.username, other_user.username])

    [owner_row] = owner_payload["rows"]
    recipient_cell = owner_row["cells"][Integer.to_string(recipient.id)]
    other_cell = owner_row["cells"][Integer.to_string(other_user.id)]

    assert recipient_cell["message_count"] == 1
    assert recipient_cell["step_count"] == 2
    assert_in_delta recipient_cell["cost"], 0.03, 0.0001
    assert other_cell["message_count"] == 1
    assert other_cell["step_count"] == 1
    assert_in_delta other_cell["cost"], 0.03, 0.0001

    recipient_payload =
      build_conn()
      |> sign_in_conn(recipient.username, recipient_password)
      |> get("/api/bff/llm-usage?from=2026-04-24&to=2026-04-24")
      |> json_response(200)

    assert Enum.map(recipient_payload["users"], & &1["username"]) == [recipient.username]
    [recipient_row] = recipient_payload["rows"]
    refute Map.has_key?(recipient_row["cells"], Integer.to_string(other_user.id))
    assert recipient_row["cells"][Integer.to_string(recipient.id)]["step_count"] == 2
  end

  defp create_provider!(actor, name) do
    LlmProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        type: :demo,
        auth_method: :api_key,
        base_url: nil,
        api_key: nil
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_configuration!(actor, provider, model_name) do
    LlmConfiguration
    |> Ash.Changeset.for_create(
      :create,
      %{
        provider_id: provider.id,
        model_name: model_name,
        note: "cfg",
        parameters: %{},
        enabled: true,
        timeout_seconds: 30,
        context_length: 2048,
        supports_cache_control: false,
        supports_image_input: false
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp share_configuration!(actor, configuration, group) do
    LlmConfigurationShare
    |> Ash.Changeset.for_create(
      :create,
      %{llm_configuration_id: configuration.id, user_group_id: group.id},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_usage_record!(attrs) do
    usage_user = Map.fetch!(attrs, :usage_user)
    configuration_owner = Map.fetch!(attrs, :configuration_owner)
    configuration = Map.fetch!(attrs, :configuration)
    provider = Map.fetch!(attrs, :provider)
    message_id = Map.fetch!(attrs, :message_id)
    step_id = Map.fetch!(attrs, :step_id)

    LlmUsageRecord
    |> Ash.Changeset.for_create(
      :create,
      %{
        usage_user_id: usage_user.id,
        usage_user_id_snapshot: usage_user.id,
        usage_username_snapshot: usage_user.username,
        configuration_owner_id: configuration_owner.id,
        configuration_owner_id_snapshot: configuration_owner.id,
        llm_configuration_id: configuration.id,
        llm_configuration_id_snapshot: configuration.id,
        llm_configuration_external_id_snapshot: configuration.external_id,
        llm_configuration_label_snapshot: "#{configuration.model_name} (#{configuration.note})",
        provider_id: provider.id,
        provider_id_snapshot: provider.id,
        provider_name_snapshot: provider.name,
        provider_type_snapshot: to_string(provider.type),
        chat_id_snapshot: Map.fetch!(attrs, :chat_id),
        chat_message_id_snapshot: message_id,
        chat_message_step_id_snapshot: step_id,
        step_sequence: Map.fetch!(attrs, :step_sequence),
        status: :done,
        response_final: true,
        occurred_at: ~U[2026-04-24 12:00:00.000000Z],
        input_tokens: 10,
        output_tokens: 5,
        cost: Map.fetch!(attrs, :cost)
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
