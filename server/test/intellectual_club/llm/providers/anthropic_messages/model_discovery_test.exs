defmodule IntellectualClub.Llm.Providers.AnthropicMessages.ModelDiscoveryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.AnthropicMessages.ModelDiscovery

  test "parses data model lists with display names" do
    assert {:ok, models} =
             ModelDiscovery.parse_models(%{
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
             })

    assert models == [
             %{
               id: "claude-sonnet-4-20250514",
               label: "Claude Sonnet 4",
               context_length: nil,
               supports_image_input: nil
             }
           ]
  end

  test "returns empty data model lists" do
    assert {:ok, []} = ModelDiscovery.parse_models(%{"data" => []})
  end

  test "rejects unsupported model list schemas" do
    assert {:error, "Unsupported model list response."} =
             ModelDiscovery.parse_models(%{"items" => []})
  end
end
