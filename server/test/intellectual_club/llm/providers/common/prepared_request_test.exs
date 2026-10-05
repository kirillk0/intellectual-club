defmodule IntellectualClub.Llm.Providers.Common.PreparedRequestTest do
  use ExUnit.Case, async: true

  import IntellectualClub.ProviderStreamHelpers

  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.AnthropicMessages
  alias IntellectualClub.Llm.Providers.Common.MissingProvider
  alias IntellectualClub.Llm.Providers.Common.PreparedRequest
  alias IntellectualClub.Llm.Providers.Demo
  alias IntellectualClub.Llm.Providers.GoogleInteractions
  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion
  alias IntellectualClub.Llm.Providers.Responses
  alias IntellectualClub.Llm.Providers.ResponsesWss

  @adapters [
    AnthropicMessages,
    Demo,
    GoogleInteractions,
    MissingProvider,
    NvidiaBuildChatCompletion,
    OpenRouterChatCompletion,
    Responses,
    ResponsesWss
  ]

  test "default preparation stringifies nested keys without an optional callback" do
    request = %{model: "test", messages: [%{role: "user", content: [%{text: "Hi"}]}]}

    assert PreparedRequest.prepare(RequestPayload, request, %{}) == %{
             "model" => "test",
             "messages" => [%{"role" => "user", "content" => [%{"text" => "Hi"}]}]
           }
  end

  test "Responses preparation scopes the cache key to the owner for HTTP and WSS" do
    request = %{model: "test", input: [], prompt_cache_key: "legacy"}
    context = %{owner_id: 12, chat_id: 34, provider_api_key: "not-part-of-the-request"}

    for adapter <- [Responses, ResponsesWss] do
      prepared = PreparedRequest.prepare(adapter, request, context)

      assert prepared == %{
               "model" => "test",
               "input" => [],
               "prompt_cache_key" => "intellectual-club:user:12"
             }

      assert adapter.prepare_request(RequestPayload.stringify_keys(request), context) == prepared
      assert PreparedRequest.prepare(adapter, prepared, context) == prepared
      assert PreparedRequest.prepare(adapter, request, %{})["prompt_cache_key"] == "legacy"
    end
  end

  test "OpenRouter preparation uses conversation affinity before the current chat" do
    request = %{model: "test", messages: [], session_id: "legacy"}
    context = %{chat_id: 34, conversation_affinity_id: 56}
    prepared = PreparedRequest.prepare(OpenRouterChatCompletion, request, context)

    assert prepared["session_id"] == "intellectual-club:chat:56"

    assert OpenRouterChatCompletion.prepare_request(
             RequestPayload.stringify_keys(request),
             context
           ) == prepared

    assert PreparedRequest.prepare(OpenRouterChatCompletion, prepared, context) == prepared

    assert PreparedRequest.prepare(OpenRouterChatCompletion, request, %{chat_id: 34})[
             "session_id"
           ] == "intellectual-club:chat:34"
  end

  test "NVIDIA preparation strips session and cache control and enables stream usage" do
    request = %{
      model: "test",
      session_id: "legacy",
      stream_options: %{include_usage: false, custom: true},
      messages: [
        %{
          role: "user",
          content: [%{type: "text", text: "Hi", cache_control: %{type: "ephemeral"}}]
        }
      ]
    }

    prepared = PreparedRequest.prepare(NvidiaBuildChatCompletion, request, %{})

    assert prepared == %{
             "model" => "test",
             "stream_options" => %{"include_usage" => true, "custom" => true},
             "messages" => [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "Hi"}]}
             ]
           }

    assert NvidiaBuildChatCompletion.prepare_request(RequestPayload.stringify_keys(request), %{}) ==
             prepared

    assert PreparedRequest.prepare(NvidiaBuildChatCompletion, prepared, %{}) == prepared
  end

  test "Anthropic preparation retains beta and resolves the version before sending" do
    request = %{model: "test", anthropic_version: " 2025-01-01 ", anthropic_beta: ["beta-a"]}
    prepared = PreparedRequest.prepare(AnthropicMessages, request, %{})

    assert prepared == %{
             "model" => "test",
             "anthropic_version" => "2025-01-01",
             "anthropic_beta" => ["beta-a"]
           }

    assert PreparedRequest.prepare(AnthropicMessages, prepared, %{}) == prepared

    assert AnthropicMessages.prepare_request(%{"anthropic_version" => nil}, %{}) == %{
             "anthropic_version" => "2023-06-01"
           }
  end

  test "builders leave final provider preparation to the persistence boundary" do
    context = %{
      history: [%{role: :user, content: "Hi"}],
      model_name: "test",
      system_prompt: "System",
      parameters: %{},
      tools: [],
      owner_id: 12,
      chat_id: 34,
      supports_image_input: false
    }

    for adapter <- @adapters do
      result = adapter.build_initial_request(context)
      assert result.request_snapshot == adapter.request_snapshot(result.raw_request)
      prepared = PreparedRequest.prepare(adapter, result.raw_request, context)
      assert PreparedRequest.prepare(adapter, prepared, context) == prepared

      case adapter do
        adapter when adapter in [Responses, ResponsesWss] ->
          refute Map.has_key?(result.raw_request, "prompt_cache_key")
          assert prepared["prompt_cache_key"] == "intellectual-club:user:12"

        OpenRouterChatCompletion ->
          refute Map.has_key?(result.raw_request, "session_id")
          assert prepared["session_id"] == "intellectual-club:chat:34"

        NvidiaBuildChatCompletion ->
          refute Map.has_key?(result.raw_request, "stream_options")
          assert prepared["stream_options"] == %{"include_usage" => true}

        _other ->
          :ok
      end
    end
  end

  test "steering preserves provider fields until the one final preparation" do
    context = %{owner_id: 99, chat_id: 88}

    for {adapter, field, initial, final} <- [
          {Responses, "prompt_cache_key", "original", "intellectual-club:user:99"},
          {ResponsesWss, "prompt_cache_key", "original", "intellectual-club:user:99"},
          {OpenRouterChatCompletion, "session_id", "original", "intellectual-club:chat:88"},
          {AnthropicMessages, "anthropic_version", " 2025-01-01 ", "2025-01-01"},
          {NvidiaBuildChatCompletion, "session_id", "original", nil}
        ] do
      request = %{"model" => "test", "input" => [], "messages" => [], field => initial}
      result = adapter.inject_steering(request, [], context)
      assert result.raw_request[field] == initial
      assert result.request_snapshot == adapter.request_snapshot(result.raw_request)
      assert PreparedRequest.prepare(adapter, result.raw_request, context)[field] == final
    end
  end

  test "configuration errors echo prepared requests without normalizing them again" do
    parent = self()

    for adapter <- @adapters -- [Demo] do
      prepared =
        PreparedRequest.prepare(
          adapter,
          %{model: "test", input: [], messages: [], custom: %{keep: true}},
          %{owner_id: 12, chat_id: 34}
        )

      assert :ok =
               adapter.stream_generate(
                 %{
                   request_payload: prepared,
                   context: %{provider_type: adapter.type(), owner_id: 98, chat_id: 76}
                 },
                 fn event -> send(parent, {:provider_event, event}) end
               )

      assert_receive {:provider_event, {:response_error, %{raw_request: ^prepared}}}
      refute_receive {:provider_event, {:trace, {:set_step_raw_request, _}}}, 0
    end
  end

  test "Demo streams the prepared logical request without a request setter" do
    parent = self()
    prepared = PreparedRequest.prepare(Demo, %{messages: [%{role: "user", content: "Hi"}]}, %{})

    assert :ok =
             Demo.stream_generate(
               %{request_payload: prepared, chunk_delay_ms: 0},
               fn event -> send(parent, {:provider_event, event}) end
             )

    assert_receive {:provider_event, {:response_complete, %{raw_request: ^prepared}}}
    refute_receive {:provider_event, {:trace, {:set_step_raw_request, _}}}, 0
  end

  describe "Demo streaming multimodal messages" do
    test "echoes text blocks in order and ignores images" do
      prepared =
        PreparedRequest.prepare(
          Demo,
          %{
            messages: [
              %{role: "user", content: "Previous prompt"},
              %{
                role: "user",
                content: [
                  %{type: "text", text: "Before the image. "},
                  %{type: "image_url", image_url: %{url: "data:image/png;base64,cG5n"}},
                  %{type: "text", text: "After the image."}
                ]
              },
              %{role: "assistant", content: "Previous answer"}
            ]
          },
          %{}
        )

      events = run_and_capture_events!(Demo, %{request_payload: prepared, chunk_delay_ms: 0})
      answer = RuntimeTrace.text_for_item_type(trace_step(events), :answer)

      assert {:response_complete, %{provider: :demo, raw_request: ^prepared}} = List.last(events)
      assert answer =~ "You said: Before the image. After the image."
      refute answer =~ "Previous prompt"
      refute answer =~ "data:image"
    end

    test "uses the empty prompt response when the last user message contains only images" do
      prepared =
        PreparedRequest.prepare(
          Demo,
          %{
            messages: [
              %{role: "user", content: "Previous prompt"},
              %{
                role: "user",
                content: [%{type: "image_url", image_url: %{url: "data:image/png;base64,cG5n"}}]
              }
            ]
          },
          %{}
        )

      events = run_and_capture_events!(Demo, %{request_payload: prepared, chunk_delay_ms: 0})
      answer = RuntimeTrace.text_for_item_type(trace_step(events), :answer)

      assert {:response_complete, %{provider: :demo, raw_request: ^prepared}} = List.last(events)
      assert answer =~ "Send a message to see an echo."
      refute answer =~ "Previous prompt"
    end
  end
end
