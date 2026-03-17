defmodule IntellectualClubWeb.AshJsonApi.LlmProvidersDuplicationTest do
  @moduledoc """
  Regression tests for LLM provider duplication through Ash JSON:API endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Llm.{LlmConfiguration, LlmConfigurationShare, LlmProvider}

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  test "POST /api/ash/llm-providers/:id/duplicate preserves credentials for owner copies", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    source = create_provider!(actor, "Owner provider")

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/llm-providers/#{source.id}/duplicate", %{
        "data" => %{
          "type" => "llm-providers",
          "attributes" => %{}
        }
      })
      |> json_response(201)

    duplicated = Ash.get!(LlmProvider, String.to_integer(response["data"]["id"]), actor: actor)

    assert duplicated.owner_id == actor.id
    assert duplicated.base_url == source.base_url
    assert duplicated.api_key == source.api_key
    assert duplicated.oauth_refresh_token == source.oauth_refresh_token
  end

  test "POST /api/ash/llm-providers/:id/duplicate clears credentials for shared copies", %{
    conn: conn
  } do
    %{user: owner} = user_fixture()
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})

    source = create_provider!(owner, "Shared provider")
    configuration = create_configuration!(owner, source, "shared-model")
    share_configuration!(owner, configuration, group)

    response =
      conn
      |> recycle()
      |> sign_in_conn(recipient.username, password)
      |> json_api_post("/api/ash/llm-providers/#{source.id}/duplicate", %{
        "data" => %{
          "type" => "llm-providers",
          "attributes" => %{}
        }
      })
      |> json_response(201)

    duplicated = Ash.get!(LlmProvider, String.to_integer(response["data"]["id"]), actor: recipient)

    assert duplicated.owner_id == recipient.id
    assert duplicated.base_url == source.base_url
    assert duplicated.api_key == nil
    assert duplicated.oauth_refresh_token == nil
  end

  defp create_provider!(actor, name) do
    LlmProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        type: :openrouter_chat_completion,
        auth_method: :api_key,
        base_url: "https://openrouter.ai/api/v1",
        api_key: "sk-test-123",
        oauth_refresh_token: "rt-test-123"
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
    |> Ash.create!()
  end
end
