defmodule IntellectualClub.Llm.Providers.OpenRouterChatCompletion.ModelDiscoveryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion.ModelDiscovery

  test "parses data model lists with metadata and label fallback" do
    assert {:ok, models} =
             ModelDiscovery.parse_models(%{
               "data" => [
                 %{
                   "id" => " openai/gpt-5-mini ",
                   "name" => " GPT 5 Mini ",
                   "context_length" => "128000",
                   "architecture" => %{"input_modalities" => ["text", "image"]}
                 },
                 %{
                   "id" => "anthropic/claude-sonnet-4.5",
                   "context_length" => 200_000,
                   "architecture" => %{"input_modalities" => ["text"]}
                 }
               ]
             })

    assert models == [
             %{
               id: "openai/gpt-5-mini",
               label: "GPT 5 Mini",
               context_length: 128_000,
               supports_image_input: true
             },
             %{
               id: "anthropic/claude-sonnet-4.5",
               label: "anthropic/claude-sonnet-4.5",
               context_length: 200_000,
               supports_image_input: false
             }
           ]
  end

  test "rejects data responses without usable models" do
    assert {:error, "Provider model list response did not include any usable models."} =
             ModelDiscovery.parse_models(%{
               "data" => [
                 %{"name" => "No id"},
                 %{"id" => "   "}
               ]
             })
  end
end
