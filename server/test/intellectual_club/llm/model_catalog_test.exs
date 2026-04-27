defmodule IntellectualClub.Llm.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.ModelCatalog

  test "parses OpenAI and OpenRouter data model lists with metadata" do
    assert {:ok, models} =
             ModelCatalog.parse_models(%{
               "data" => [
                 %{
                   "id" => "openai/gpt-5-mini",
                   "name" => "GPT 5 Mini",
                   "context_length" => 128_000,
                   "architecture" => %{"input_modalities" => ["text", "image"]}
                 }
               ]
             })

    assert models == [
             %{
               id: "openai/gpt-5-mini",
               label: "GPT 5 Mini",
               context_length: 128_000,
               supports_image_input: true
             }
           ]
  end

  test "parses Codex models lists with metadata" do
    assert {:ok, models} =
             ModelCatalog.parse_models(%{
               "models" => [
                 %{
                   "slug" => "gpt-5.4",
                   "display_name" => "gpt-5.4",
                   "context_window" => 272_000,
                   "max_context_window" => 1_000_000,
                   "input_modalities" => ["text", "image"]
                 }
               ]
             })

    assert models == [
             %{
               id: "gpt-5.4",
               label: "gpt-5.4",
               context_length: 272_000,
               supports_image_input: true
             }
           ]
  end

  test "rejects unsupported model list schemas" do
    assert {:error, "Unsupported model list response."} =
             ModelCatalog.parse_models(%{"items" => []})
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
end
