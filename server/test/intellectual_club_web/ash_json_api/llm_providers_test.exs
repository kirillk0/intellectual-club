defmodule IntellectualClubWeb.AshJsonApi.LlmProvidersTest do
  @moduledoc """
  LLM providers through the AshJsonApi endpoints: credential status, sharing
  and duplication.
  """

  use IntellectualClubWeb.ConnCase, async: true

  import IntellectualClubWeb.AshJsonApiContract

  alias IntellectualClub.Llm.LlmProvider

  @secret_keys ["api_key", "oauth_refresh_token"]

  @credentials [
    {"API key", %{type: :openrouter_chat_completion, api_key: "sk_test_123"}, ["api_key"]},
    {"OAuth refresh token", :refresh_token_provider, ["oauth_refresh_token"]},
    {"no credentials", %{type: :demo, base_url: nil}, []}
  ]

  describe "GET /api/ash/llm-providers/:id" do
    for {name, attrs, present} <- @credentials do
      test "reports credentials_present without secrets for #{name}" do
        %{user: actor} = owner = user_fixture()
        provider = create_provider!(actor, provider_attrs(unquote(Macro.escape(attrs))))

        attributes = api_attributes!(owner, "/api/ash/llm-providers/#{provider.id}")

        assert attributes["credentials_present"] == unquote(present)
        for key <- @secret_keys, do: refute(Map.has_key?(attributes, key))
      end
    end

    test "lists a provider shared through several configurations once and loads it by id" do
      %{user: owner} = user_fixture()
      %{user: recipient} = recipient_fixture = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})
      provider = create_provider!(owner, provider_attrs(:refresh_token_provider))

      for model <- ["shared-model-a", "shared-model-b"] do
        configuration = create_configuration!(owner, provider: provider, model_name: model)
        share_configuration!(owner, configuration, group)
      end

      index = api_get!(recipient_fixture, "/api/ash/llm-providers")
      assert Enum.count(ids_from_data(index), &(&1 == provider.id)) == 1

      attributes = api_attributes!(recipient_fixture, "/api/ash/llm-providers/#{provider.id}")
      assert attributes["name"] == provider.name
      assert attributes["shared_incoming"] == true
      assert attributes["shared_outgoing"] == true
      assert attributes["credentials_present"] == ["oauth_refresh_token"]
      for key <- @secret_keys, do: refute(Map.has_key?(attributes, key))
    end
  end

  describe "POST /api/ash/llm-providers/:id/duplicate" do
    for {copier, keeps_credentials?} <- [owner: true, "shared recipient": false] do
      test "#{if keeps_credentials?, do: "preserves", else: "clears"} credentials for #{copier} copies" do
        %{user: owner} = owner_fixture = user_fixture()
        %{user: recipient} = recipient_fixture = user_fixture()
        %{group: group} = user_group_fixture(%{users: [owner, recipient]})

        source =
          create_provider!(owner,
            type: :openrouter_chat_completion,
            api_key: "sk-test-123",
            oauth_refresh_token: "rt-test-123"
          )

        configuration = create_configuration!(owner, provider: source)
        share_configuration!(owner, configuration, group)

        {%{user: copier} = copier_fixture, expected_credentials} =
          if unquote(keeps_credentials?),
            do: {owner_fixture, {"sk-test-123", "rt-test-123"}},
            else: {recipient_fixture, {nil, nil}}

        {copy_id, _response} =
          duplicate!(copier_fixture, "/api/ash/llm-providers", "llm-providers", source.id)

        copy = Ash.get!(LlmProvider, copy_id, actor: copier)
        assert copy.owner_id == copier.id
        assert copy.base_url == source.base_url
        assert {copy.api_key, copy.oauth_refresh_token} == expected_credentials
      end
    end
  end

  defp provider_attrs(:refresh_token_provider) do
    %{
      type: :responses,
      auth_method: :openai_oauth_refresh_token,
      base_url: "https://api.openai.com/v1",
      api_key: nil,
      oauth_refresh_token: "rt_test_123"
    }
  end

  defp provider_attrs(attrs), do: attrs
end
