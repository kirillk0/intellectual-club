defmodule IntellectualClub.Llm.ModelDiscoveryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.ModelCatalog
  alias IntellectualClub.Llm.Providers.AnthropicMessages
  alias IntellectualClub.Llm.Providers.GoogleInteractions
  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion
  alias IntellectualClub.Llm.Providers.Responses

  @no_usable_models "Provider model list response did not include any usable models."

  defp model(id, label, context_length, supports_image_input) do
    %{
      id: id,
      label: label,
      context_length: context_length,
      supports_image_input: supports_image_input
    }
  end

  describe "parse_models/1" do
    @cases [
      {"Anthropic data lists use display names", AnthropicMessages.ModelDiscovery,
       %{
         "data" => [
           %{
             "id" => "claude-sonnet-4-20250514",
             "display_name" => "Claude Sonnet 4",
             "type" => "model"
           }
         ],
         "first_id" => "claude-sonnet-4-20250514",
         "has_more" => false,
         "last_id" => "claude-sonnet-4-20250514"
       }, {:ok, [{"claude-sonnet-4-20250514", "Claude Sonnet 4", nil, nil}]}},
      {"Anthropic accepts empty data lists", AnthropicMessages.ModelDiscovery, %{"data" => []},
       {:ok, []}},
      {"Anthropic rejects unsupported schemas", AnthropicMessages.ModelDiscovery,
       %{"items" => []}, {:error, "Unsupported model list response."}},
      {"Google strips the models/ prefix and derives image input from the family",
       GoogleInteractions.ModelDiscovery,
       %{
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
       },
       {:ok,
        [
          {"gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite", 1_048_576, true},
          {"gemma-4-26b-a4b-it", "Gemma 4 26B A4B IT", 262_144, false}
        ]}},
      {"NVIDIA sparse lists do not invent capability metadata",
       NvidiaBuildChatCompletion.ModelDiscovery,
       %{
         "object" => "list",
         "data" => [
           %{
             "id" => " nvidia/nemotron-3-nano-30b-a3b ",
             "object" => "model",
             "created" => 735_790_403,
             "owned_by" => "nvidia"
           },
           %{
             "id" => "meta/llama-3.1-70b-instruct",
             "object" => "model",
             "created" => 735_790_403,
             "owned_by" => "meta"
           }
         ]
       },
       {:ok,
        [
          {"nvidia/nemotron-3-nano-30b-a3b", "nvidia/nemotron-3-nano-30b-a3b", nil, nil},
          {"meta/llama-3.1-70b-instruct", "meta/llama-3.1-70b-instruct", nil, nil}
        ]}},
      {"NVIDIA rejects lists without usable ids", NvidiaBuildChatCompletion.ModelDiscovery,
       %{"data" => [%{"owned_by" => "nvidia"}, %{"id" => "   "}]}, {:error, @no_usable_models}},
      {"OpenRouter parses metadata and falls back to the id as label",
       OpenRouterChatCompletion.ModelDiscovery,
       %{
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
       },
       {:ok,
        [
          {"openai/gpt-5-mini", "GPT 5 Mini", 128_000, true},
          {"anthropic/claude-sonnet-4.5", "anthropic/claude-sonnet-4.5", 200_000, false}
        ]}},
      {"OpenRouter rejects lists without usable ids", OpenRouterChatCompletion.ModelDiscovery,
       %{"data" => [%{"name" => "No id"}, %{"id" => "   "}]}, {:error, @no_usable_models}},
      {"Responses parses OpenAI-compatible data lists", Responses.ModelDiscovery,
       %{
         "data" => [
           %{
             "id" => "gpt-5.5",
             "name" => "GPT 5.5",
             "context_length" => 272_000,
             "architecture" => %{"input_modalities" => ["text", "image"]}
           }
         ]
       }, {:ok, [{"gpt-5.5", "GPT 5.5", 272_000, true}]}},
      {"Responses parses Codex model lists", Responses.ModelDiscovery,
       %{
         "models" => [
           %{
             "slug" => "gpt-5.4",
             "display_name" => "gpt-5.4",
             "context_window" => 272_000,
             "max_context_window" => 1_000_000,
             "input_modalities" => ["text", "image"]
           }
         ]
       }, {:ok, [{"gpt-5.4", "gpt-5.4", 272_000, true}]}}
    ]

    for {name, module, payload, expected} <- @cases do
      @module module
      @payload payload
      @expected expected

      test name do
        expected =
          case @expected do
            {:ok, models} -> {:ok, Enum.map(models, fn {i, l, c, s} -> model(i, l, c, s) end)}
            error -> error
          end

        assert @module.parse_models(@payload) == expected
      end
    end
  end

  describe "ModelCatalog.list_models/1" do
    test "delegates supported providers to their provider modules" do
      assert {:ok, []} = ModelCatalog.list_models(%{type: "demo"})
    end

    test "returns missing credential errors without external requests" do
      assert {:error, "Provider API key is not set"} =
               ModelCatalog.list_models(%{
                 id: 1,
                 type: "openrouter_chat_completion",
                 auth_method: "api_key",
                 base_url: "http://127.0.0.1:1",
                 api_key: nil,
                 oauth_refresh_token: nil
               })
    end

    test "returns controlled errors for unknown provider types" do
      assert {:error, "Provider type is not supported for model discovery."} =
               ModelCatalog.list_models(%{type: "unknown_provider_type"})
    end
  end
end
