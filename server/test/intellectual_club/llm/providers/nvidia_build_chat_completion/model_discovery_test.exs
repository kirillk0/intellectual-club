defmodule IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion.ModelDiscoveryTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion.ModelDiscovery

  test "parses sparse NVIDIA model lists without inventing capability metadata" do
    assert {:ok, models} =
             ModelDiscovery.parse_models(%{
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
             })

    assert models == [
             %{
               id: "nvidia/nemotron-3-nano-30b-a3b",
               label: "nvidia/nemotron-3-nano-30b-a3b",
               context_length: nil,
               supports_image_input: nil
             },
             %{
               id: "meta/llama-3.1-70b-instruct",
               label: "meta/llama-3.1-70b-instruct",
               context_length: nil,
               supports_image_input: nil
             }
           ]
  end

  test "rejects responses without usable model ids" do
    assert {:error, "Provider model list response did not include any usable models."} =
             ModelDiscovery.parse_models(%{
               "data" => [%{"owned_by" => "nvidia"}, %{"id" => "   "}]
             })
  end
end
