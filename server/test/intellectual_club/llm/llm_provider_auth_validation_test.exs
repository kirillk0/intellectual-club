defmodule IntellectualClub.Llm.LlmProviderAuthValidationTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Llm.LlmProvider

  test "allows responses provider with OpenAI OAuth refresh token and no API key" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Responses OAuth",
          type: :responses,
          auth_method: :openai_oauth_refresh_token,
          base_url: "https://api.openai.com/v1",
          oauth_refresh_token: "rt_test"
        },
        actor: actor
      )
      |> Ash.create!()

    assert provider.type == "responses"
    assert provider.auth_method == "openai_oauth_refresh_token"
  end

  test "rejects OpenAI OAuth auth method for non-responses providers" do
    %{user: actor} = user_fixture()

    assert_raise Ash.Error.Invalid, fn ->
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "OpenRouter OAuth",
          type: :openrouter_chat_completion,
          auth_method: :openai_oauth_refresh_token,
          base_url: "https://openrouter.ai/api/v1",
          oauth_refresh_token: "rt_test"
        },
        actor: actor
      )
      |> Ash.create!()
    end
  end
end
