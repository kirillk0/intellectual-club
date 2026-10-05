defmodule IntellectualClub.Llm.Providers.ImageMapperTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.AnthropicMessages
  alias IntellectualClub.Llm.Providers.Common.MissingProvider
  alias IntellectualClub.Llm.Providers.Demo
  alias IntellectualClub.Llm.Providers.GoogleInteractions
  alias IntellectualClub.TestSupport.LlmProviders.ImageMapperDummy
  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion
  alias IntellectualClub.Llm.Providers.Responses
  alias IntellectualClub.Llm.Providers.ResponsesWss

  @adapters [
    Responses,
    ResponsesWss,
    AnthropicMessages,
    GoogleInteractions,
    OpenRouterChatCompletion,
    NvidiaBuildChatCompletion
  ]
  @mime "image/png"
  @marker %{
    "version" => 1,
    "reference_key" => "11111111-1111-4111-8111-111111111111",
    "source_file_external_id" => "11111111-1111-4111-8111-111111111111",
    "rendition" => %{"kind" => "fit", "max_edge_px" => 2_000, "format" => "preserve"},
    "encoding" => "data_url",
    "mime_type" => @mime
  }

  for adapter <- @adapters do
    @adapter adapter

    test "#{inspect(adapter)} exposes exactly a neutral reference and preserves :keep" do
      adapter = @adapter
      marker = marker(adapter)
      request = request(adapter, [image(adapter, %{"$intellectual_club_file" => marker})])

      {mapped, [reference]} =
        adapter.map_request_images(request, [], fn reference, acc ->
          {:keep, [reference | acc]}
        end)

      assert mapped == request

      assert Map.keys(reference) |> Enum.sort() ==
               Enum.sort([:marker, :encoding, :mime_type, :format_key, :format])

      assert reference.marker == marker
      assert reference.encoding == encoding(adapter)
      assert reference.mime_type == @mime
      assert reference.format_key == format_key(adapter)
      assert reference.format.("cG5n", @mime) == wire(adapter, "cG5n", @mime)
    end

    test "#{inspect(adapter)} owns marker, wire and fallback block updates" do
      adapter = @adapter
      marker = marker(adapter)
      block = image(adapter, %{"$intellectual_club_file" => marker})
      request = request(adapter, [block])
      updated_marker = Map.put(marker, "mime_type", "image/webp")
      updated_wire = wire(adapter, "d2VicA==", "image/webp")

      for {change, expected} <- [
            {{:marker, updated_marker, "image/webp"},
             image(adapter, %{"$intellectual_club_file" => updated_marker}, "image/webp")},
            {{:wire, updated_wire, "image/webp"}, image(adapter, updated_wire, "image/webp")},
            {{:omit, "Not an image"}, fallback(adapter, "Not an image")}
          ] do
        assert {mapped, 1} =
                 adapter.map_request_images(request, 0, fn _reference, count ->
                   {change, count + 1}
                 end)

        assert mapped == request(adapter, [expected])
      end
    end

    test "#{inspect(adapter)} ignores legacy strings, wrong shapes, and opaque JSON" do
      adapter = @adapter
      block = image(adapter, %{"$intellectual_club_file" => marker(adapter)})

      opaque = %{
        "type" => "tool_use",
        "input" => block,
        "arguments" => block,
        "content" => [block]
      }

      result_map = %{"type" => "function_result", "result" => %{"content" => [block]}}
      tool_map = %{"type" => "tool_result", "content" => %{"content" => [block]}}
      no_container = %{"content" => [block]}
      legacy = image(adapter, wire(adapter, "bGVnYWN5", @mime))
      invalid_marker = image(adapter, %{"$intellectual_club_file" => "opaque"})
      foreign_block = foreign_image(adapter)

      request =
        request(adapter, [
          block,
          opaque,
          result_map,
          tool_map,
          no_container,
          legacy,
          invalid_marker,
          foreign_block
        ])
        |> Map.put("metadata", block)
        |> Map.put("tools", [%{"parameters" => block}])
        |> Map.put(other_root(adapter), [%{"role" => "user", "content" => [block]}])

      assert {mapped, 1} =
               adapter.map_request_images(request, 0, fn _reference, count ->
                 {:keep, count + 1}
               end)

      assert mapped == request
    end

    test "#{inspect(adapter)} traverses image-bearing tool result containers in order" do
      adapter = @adapter
      block = image(adapter, %{"$intellectual_club_file" => marker(adapter)})
      request = request(adapter, [block, tool_result(adapter, [block, block])])

      assert {mapped, 3} =
               adapter.map_request_images(request, 0, fn _reference, count ->
                 {{:omit, "image #{count}"}, count + 1}
               end)

      assert mapped ==
               request(adapter, [
                 fallback(adapter, "image 0"),
                 tool_result(adapter, [fallback(adapter, "image 1"), fallback(adapter, "image 2")])
               ])
    end
  end

  test "native MIME fields are exposed without substituting the marker MIME" do
    for adapter <- [AnthropicMessages, GoogleInteractions] do
      for native_mime <- [nil, "image/jpeg"] do
        block = image(adapter, %{"$intellectual_club_file" => marker(adapter)}, native_mime)

        assert {_request, [reference]} =
                 adapter.map_request_images(request(adapter, [block]), [], fn reference, acc ->
                   {:keep, [reference | acc]}
                 end)

        assert reference.mime_type == native_mime
        assert reference.marker["mime_type"] == @mime
      end
    end
  end

  test "Anthropic omission preserves only map-valued cache control" do
    for cache_control <- [nil, "opaque", %{"type" => "ephemeral", "ttl" => "1h"}] do
      block = image(AnthropicMessages, %{"$intellectual_club_file" => marker(AnthropicMessages)})
      block = Map.put(block, "cache_control", cache_control)

      {mapped, nil} =
        AnthropicMessages.map_request_images(
          request(AnthropicMessages, [block]),
          nil,
          fn _reference, acc -> {{:omit, "omitted"}, acc} end
        )

      [container] = mapped["messages"]
      [fallback] = container["content"]
      assert Map.get(fallback, "cache_control") == if(is_map(cache_control), do: cache_control)
      refute Map.has_key?(fallback, "source")
    end
  end

  test "a new provider controls different roots, containers and image formatting" do
    marker = Map.put(@marker, "encoding", "base64")

    block = %{
      "kind" => "picture",
      "mime" => @mime,
      "attachment" => %{"$intellectual_club_file" => marker}
    }

    request = %{"packets" => [%{"kind" => "packet", "parts" => [block]}], "metadata" => block}

    {mapped, [:visited]} =
      ImageMapperDummy.map_request_images(request, [], fn reference, acc ->
        assert reference.format_key == {ImageMapperDummy, :picture_v1}
        assert reference.encoding == "base64"
        {{:wire, reference.format.("cG5n", @mime), @mime}, [:visited | acc]}
      end)

    assert get_in(mapped, ["packets", Access.at(0), "parts", Access.at(0), "attachment"]) ==
             "image/png:cG5n"

    assert mapped["metadata"] == block
  end

  test "unsupported providers are no-ops" do
    request = request(Responses, [image(Responses, %{"$intellectual_club_file" => @marker})])

    for adapter <- [Demo, MissingProvider] do
      assert adapter.map_request_images(request, :unchanged, fn _, _ ->
               flunk("unexpected image")
             end) ==
               {request, :unchanged}
    end
  end

  defp marker(adapter), do: Map.put(@marker, "encoding", encoding(adapter))
  defp encoding(adapter) when adapter in [AnthropicMessages, GoogleInteractions], do: "base64"
  defp encoding(_adapter), do: "data_url"
  defp format_key(adapter) when adapter in [AnthropicMessages, GoogleInteractions], do: :base64
  defp format_key(_adapter), do: :data_url

  defp wire(adapter, base64, _mime) when adapter in [AnthropicMessages, GoogleInteractions],
    do: base64

  defp wire(_adapter, base64, mime), do: "data:#{mime};base64," <> base64

  defp request(adapter, blocks) when adapter in [Responses, ResponsesWss],
    do: %{"input" => [%{"type" => "message", "role" => "user", "content" => blocks}]}

  defp request(GoogleInteractions, blocks),
    do: %{"input" => [%{"type" => "user_input", "content" => blocks}]}

  defp request(_adapter, blocks), do: %{"messages" => [%{"role" => "user", "content" => blocks}]}

  defp other_root(adapter) when adapter in [Responses, ResponsesWss, GoogleInteractions],
    do: "messages"

  defp other_root(_adapter), do: "input"

  defp image(adapter, value, mime \\ @mime)

  defp image(adapter, value, _mime) when adapter in [Responses, ResponsesWss],
    do: %{"type" => "input_image", "image_url" => value, "detail" => "high"}

  defp image(AnthropicMessages, value, mime),
    do: %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => mime, "data" => value, "custom" => true},
      "cache_control" => %{"type" => "ephemeral"}
    }

  defp image(GoogleInteractions, value, mime),
    do: %{"type" => "image", "mime_type" => mime, "data" => value, "custom" => true}

  defp image(_adapter, value, _mime),
    do: %{"type" => "image_url", "image_url" => %{"url" => value, "detail" => "high"}}

  defp fallback(adapter, text) when adapter in [Responses, ResponsesWss],
    do: %{"type" => "input_text", "text" => text}

  defp fallback(AnthropicMessages, text),
    do: %{"type" => "text", "text" => text, "cache_control" => %{"type" => "ephemeral"}}

  defp fallback(_adapter, text), do: %{"type" => "text", "text" => text}

  defp foreign_image(adapter) when adapter in [Responses, ResponsesWss],
    do: image(OpenRouterChatCompletion, %{"$intellectual_club_file" => @marker})

  defp foreign_image(_adapter), do: image(Responses, %{"$intellectual_club_file" => @marker})

  defp tool_result(GoogleInteractions, blocks),
    do: %{"type" => "function_result", "result" => blocks, "call_id" => "call_1"}

  defp tool_result(_adapter, blocks),
    do: %{"type" => "tool_result", "content" => blocks, "tool_use_id" => "call_1"}
end
