defmodule IntellectualClubWeb.AshJsonApi.LlmProvidersCredentialsStatusTest do
  @moduledoc """
  Regression tests for LLM provider credentials status in Ash JSON:API responses.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationShare, LlmProvider}

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end

  test "GET /api/ash/llm-providers/:id exposes credentials_present without exposing secrets", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    with_api_key =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "With API key",
          type: :openrouter_chat_completion,
          auth_method: :api_key,
          base_url: "https://openrouter.ai/api/v1",
          api_key: "sk_test_123"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    with_refresh_token =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "With refresh token",
          type: :responses,
          auth_method: :openai_oauth_refresh_token,
          base_url: "https://api.openai.com/v1",
          oauth_refresh_token: "rt_test_123"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    without_credentials =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Without credentials",
          type: :demo,
          auth_method: :api_key,
          base_url: nil
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response_api_key =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/llm-providers/#{with_api_key.id}")
      |> json_response(200)

    attrs_api_key = response_api_key["data"]["attributes"]
    assert attrs_api_key["credentials_present"] == ["api_key"]
    refute Map.has_key?(attrs_api_key, "api_key")
    refute Map.has_key?(attrs_api_key, "oauth_refresh_token")

    response_refresh_token =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/llm-providers/#{with_refresh_token.id}")
      |> json_response(200)

    attrs_refresh_token = response_refresh_token["data"]["attributes"]
    assert attrs_refresh_token["credentials_present"] == ["oauth_refresh_token"]
    refute Map.has_key?(attrs_refresh_token, "api_key")
    refute Map.has_key?(attrs_refresh_token, "oauth_refresh_token")

    response_without =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get("/api/ash/llm-providers/#{without_credentials.id}")
      |> json_response(200)

    attrs_without = response_without["data"]["attributes"]
    assert attrs_without["credentials_present"] == []
    refute Map.has_key?(attrs_without, "api_key")
    refute Map.has_key?(attrs_without, "oauth_refresh_token")
  end

  test "shared providers stay unique in index and load by id when multiple shared configurations point to them",
       %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Shared responses provider",
          type: :responses,
          auth_method: :openai_oauth_refresh_token,
          base_url: "https://api.openai.com/v1",
          oauth_refresh_token: "rt_test_123"
        },
        actor: owner
      )
      |> Ash.create!(actor: owner)

    configuration_a = create_configuration!(owner, provider, "shared-model-a")
    configuration_b = create_configuration!(owner, provider, "shared-model-b")

    share_configuration!(owner, configuration_a, group)
    share_configuration!(owner, configuration_b, group)

    index_response =
      conn
      |> recycle()
      |> sign_in_conn(recipient.username, password)
      |> json_api_get("/api/ash/llm-providers")
      |> json_response(200)

    provider_ids =
      index_response["data"]
      |> Enum.filter(&(&1["type"] == "llm-providers"))
      |> Enum.map(&String.to_integer(&1["id"]))

    assert Enum.count(provider_ids, &(&1 == provider.id)) == 1

    show_response =
      conn
      |> recycle()
      |> sign_in_conn(recipient.username, password)
      |> json_api_get("/api/ash/llm-providers/#{provider.id}")
      |> json_response(200)

    attrs = show_response["data"]["attributes"]
    assert attrs["name"] == "Shared responses provider"
    assert attrs["shared_incoming"] == true
    assert attrs["shared_outgoing"] == true
    assert attrs["credentials_present"] == ["oauth_refresh_token"]
    refute Map.has_key?(attrs, "api_key")
    refute Map.has_key?(attrs, "oauth_refresh_token")
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
    |> Ash.create!()
  end
end
