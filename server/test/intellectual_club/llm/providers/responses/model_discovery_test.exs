defmodule IntellectualClub.Llm.Providers.Responses.ModelDiscoveryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.Responses.ModelDiscovery

  test "parses OpenAI-compatible data model lists with metadata" do
    assert {:ok, models} =
             ModelDiscovery.parse_models(%{
               "data" => [
                 %{
                   "id" => "gpt-5.5",
                   "name" => "GPT 5.5",
                   "context_length" => 272_000,
                   "architecture" => %{"input_modalities" => ["text", "image"]}
                 }
               ]
             })

    assert models == [
             %{
               id: "gpt-5.5",
               label: "GPT 5.5",
               context_length: 272_000,
               supports_image_input: true
             }
           ]
  end

  test "parses Codex models lists with metadata" do
    assert {:ok, models} =
             ModelDiscovery.parse_models(%{
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
end
