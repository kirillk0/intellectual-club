defmodule IntellectualClub.Llm.Providers.AnthropicMessages.ApiTest do
  use ExUnit.Case, async: true

  import IntellectualClub.ProviderStreamHelpers
  import IntellectualClub.TestHttpServer

  alias IntellectualClub.Generation.History
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.Providers.AnthropicMessages
  alias IntellectualClub.Llm.Providers.AnthropicMessages.Api

  @payload %{
    "model" => "claude-sonnet-4-20250514",
    "max_tokens" => 128,
    "messages" => [],
    "stream" => true
  }

  describe "stream_generate/2" do
    test "sends Anthropic headers and streams text and tool calls into trace events" do
      payload =
        Map.merge(@payload, %{
          "anthropic_version" => "2025-01-01",
          "anthropic_beta" => ["beta-a", "beta-b"],
          "messages" => [%{"role" => "user", "content" => [%{"type" => "text", "text" => "Hi"}]}]
        })

      {events, [request]} =
        stream!(
          [message_start(%{"input_tokens" => 10, "output_tokens" => 1})] ++
            block(0, %{"type" => "text", "text" => ""}, [
              %{"type" => "text_delta", "text" => "Checking."}
            ]) ++
            tool_use_block(1, [~s({"city":), ~s("Paris"})]) ++
            message_end("tool_use", 20),
          payload
        )

      assert {"x-api-key", "test-key"} in request.headers
      assert {"anthropic-version", "2025-01-01"} in request.headers
      assert {"anthropic-beta", "beta-a,beta-b"} in request.headers
      assert request.payload == Map.drop(payload, ["anthropic_version", "anthropic_beta"])

      assert {:trace, {:append_text, "answer:0", :answer, 1, "Checking."}} in events

      assert Enum.any?(events, fn
               {:trace, {:set_opaque, "tc:toolu_1", :tool_call, 10_000, opaque}} ->
                 opaque["tool_call_id"] == "toolu_1" and
                   opaque["name"] == "weather__get" and
                   opaque["arguments"] == %{"city" => "Paris"} and
                   get_in(opaque, ["raw", "input"]) == %{"city" => "Paris"}

               _other ->
                 false
             end)

      meta = response_complete!(events)
      assert meta.raw_response["stop_reason"] == "tool_use"
      assert meta.raw_response["usage"] == %{"input_tokens" => 10, "output_tokens" => 20}

      assert meta.usage == %{
               input_tokens: 10,
               output_tokens: 20,
               cached_input_tokens: nil,
               reasoning_tokens: nil,
               cost: nil
             }

      assert meta.raw_response["content"] == [
               %{"type" => "text", "text" => "Checking."},
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "weather__get",
                 "input" => %{"city" => "Paris"}
               }
             ]
    end

    test "classifies a tool call after thinking as a tool call, not an answer" do
      {events, _requests} =
        stream!(
          [message_start(%{"input_tokens" => 10, "output_tokens" => 1})] ++
            block(0, %{"type" => "thinking", "thinking" => ""}, [
              %{"type" => "thinking_delta", "thinking" => "Need data."}
            ]) ++ tool_use_block(1, [~s({"city":"Paris"})]) ++ message_end("tool_use", 20)
        )

      items = RuntimeTrace.persistable(trace_step(events)).items
      sequences = Enum.map(items, & &1.sequence)

      assert Enum.map(items, &{&1.sequence, &1.type}) == [{1, :reasoning}, {2, :tool_call}]
      assert sequences == Enum.uniq(sequences)
      refute Enum.any?(items, &(&1.type == :answer))
    end

    test "persists thinking signatures and opaque-only blocks for full history in native order" do
      {events, _requests} =
        stream!(
          [%{"type" => "message_start", "message" => %{"role" => "assistant", "content" => []}}] ++
            block(0, %{"type" => "thinking", "thinking" => ""}, [
              %{"type" => "thinking_delta", "thinking" => "Think "},
              %{"type" => "thinking_delta", "thinking" => "carefully"},
              %{"type" => "signature_delta", "signature" => "sig-"},
              %{"type" => "signature_delta", "signature" => "complete"}
            ]) ++
            block(1, %{"type" => "text", "text" => "Answer"}, []) ++
            block(2, %{"type" => "redacted_thinking", "data" => "encrypted-data"}, []) ++
            [%{"type" => "message_stop"}],
          %{"model" => "test", "messages" => [], "stream" => true}
        )

      stored = RuntimeTrace.persistable(trace_step(events))
      assert Enum.map(stored.items, & &1.type) == [:reasoning, :answer, :reasoning]

      assert Enum.all?(Enum.filter(stored.items, &(&1.type == :reasoning)), fn item ->
               Enum.any?(item.contents, &(&1.kind == :opaque))
             end)

      history = [
        %{role: :assistant, llm_configuration_id: 4, steps: [Map.delete(stored, :raw_response)]}
      ]

      request =
        AnthropicMessages.build_initial_request(%{
          history: History.for_mode(history, :full, 4),
          model_name: "test"
        }).raw_request

      assert [%{"content" => [thinking, answer, redacted]}] = request["messages"]

      assert thinking == %{
               "type" => "thinking",
               "thinking" => "Think carefully",
               "signature" => "sig-complete"
             }

      assert answer == %{"type" => "text", "text" => "Answer"}
      assert redacted == %{"type" => "redacted_thinking", "data" => "encrypted-data"}
    end
  end

  describe "usage normalization" do
    @usage_cases [
      {"cache tokens, nested thinking tokens and numeric cost",
       %{
         "input_tokens" => 10,
         "cache_read_input_tokens" => 20,
         "cache_creation_input_tokens" => 30,
         "output_tokens" => 1,
         "output_tokens_details" => %{"thinking_tokens" => 937},
         "cost" => 0.012036
       },
       %{
         input_tokens: 60,
         output_tokens: 7,
         cached_input_tokens: 20,
         reasoning_tokens: 937,
         cost: 0.012036
       }},
      {"direct thinking tokens and numeric string cost",
       %{
         "input_tokens" => 10,
         "output_tokens" => 1,
         "thinking_tokens" => "294",
         "cost" => "0.0195436"
       },
       %{
         input_tokens: 10,
         output_tokens: 7,
         cached_input_tokens: nil,
         reasoning_tokens: 294,
         cost: 0.0195436
       }}
    ]

    for {name, initial_usage, expected} <- @usage_cases do
      @initial_usage initial_usage
      @expected expected

      test "normalizes #{name}" do
        {events, _requests} =
          stream!([message_start(@initial_usage) | message_end("end_turn", 7)])

        step = trace_step(events)
        meta = response_complete!(events)

        assert meta.usage == @expected

        for field <- [:input_tokens, :output_tokens, :cached_input_tokens, :reasoning_tokens] do
          assert Map.fetch!(step, field) == Map.fetch!(@expected, field)
        end

        assert_in_delta step.cost, @expected.cost, 1.0e-9
        assert meta.raw_response["usage"] == Map.put(@initial_usage, "output_tokens", 7)
      end
    end
  end

  defp stream!(events, payload \\ @payload) do
    {base_url, agent} =
      start_scripted_server!(%{"/messages" => [{200, anthropic_sse_chunks(events)}]},
        record: :request
      )

    events =
      run_and_capture_events!(Api, %{
        base_url: base_url,
        api_key: "test-key",
        request_payload: payload,
        timeout_ms: provider_deadline_ms(),
        connect_timeout_ms: provider_deadline_ms()
      })

    {events, scripted_requests(agent, "/messages")}
  end

  defp response_complete!(events) do
    case for({:response_complete, meta} <- events, do: meta) do
      [meta] ->
        meta

      metas ->
        flunk("expected one :response_complete, got #{inspect(metas)} in #{inspect(events)}")
    end
  end

  defp message_start(usage) do
    %{
      "type" => "message_start",
      "message" => %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-sonnet-4-20250514",
        "content" => [],
        "stop_reason" => nil,
        "usage" => usage
      }
    }
  end

  defp block(index, content_block, deltas) do
    [%{"type" => "content_block_start", "index" => index, "content_block" => content_block}] ++
      Enum.map(deltas, &%{"type" => "content_block_delta", "index" => index, "delta" => &1}) ++
      [%{"type" => "content_block_stop", "index" => index}]
  end

  defp tool_use_block(index, json_parts) do
    block(
      index,
      %{"type" => "tool_use", "id" => "toolu_1", "name" => "weather__get", "input" => %{}},
      Enum.map(json_parts, &%{"type" => "input_json_delta", "partial_json" => &1})
    )
  end

  defp message_end(stop_reason, output_tokens) do
    [
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => stop_reason, "stop_sequence" => nil},
        "usage" => %{"output_tokens" => output_tokens}
      },
      %{"type" => "message_stop"}
    ]
  end
end
