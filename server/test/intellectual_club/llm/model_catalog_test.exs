defmodule IntellectualClub.Llm.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.ModelCatalog

  test "delegates supported providers to their provider modules" do
    assert {:ok, []} = ModelCatalog.list_models(%{type: :demo})
  end

  test "returns missing credential errors without external requests" do
    assert {:error, "Provider API key is not set"} =
             ModelCatalog.list_models(%{
               id: 1,
               type: :openrouter_chat_completion,
               auth_method: :api_key,
               base_url: "http://127.0.0.1:1",
               api_key: nil,
               oauth_refresh_token: nil
             })
  end

  test "returns controlled errors for unknown provider types" do
    assert {:error, "Provider type is not supported for model discovery."} =
             ModelCatalog.list_models(%{type: :unknown_provider_type})
  end
end
