defmodule IntellectualClub.Llm.Providers.GoogleInteractions.ModelDiscoveryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.GoogleInteractions.ModelDiscovery

  test "parses Google model lists with short interaction model ids" do
    assert {:ok, models} =
             ModelDiscovery.parse_models(%{
               "models" => [
                 %{
                   "name" => "models/gemini-2.5-flash-lite",
                   "displayName" => "Gemini 2.5 Flash-Lite",
                   "inputTokenLimit" => 1_048_576,
                   "outputTokenLimit" => 65_536,
                   "supportedGenerationMethods" => ["generateContent", "countTokens"]
                 },
                 %{
                   "name" => "models/gemma-4-26b-a4b-it",
                   "displayName" => "Gemma 4 26B A4B IT",
                   "inputTokenLimit" => 262_144,
                   "outputTokenLimit" => 32_768,
                   "supportedGenerationMethods" => ["generateContent", "countTokens"]
                 }
               ]
             })

    assert models == [
             %{
               id: "gemini-2.5-flash-lite",
               label: "Gemini 2.5 Flash-Lite",
               context_length: 1_048_576,
               supports_image_input: true
             },
             %{
               id: "gemma-4-26b-a4b-it",
               label: "Gemma 4 26B A4B IT",
               context_length: 262_144,
               supports_image_input: false
             }
           ]
  end
end
