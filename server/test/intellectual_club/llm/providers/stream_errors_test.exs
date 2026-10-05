defmodule IntellectualClub.Llm.Providers.StreamErrorsTest do
  @moduledoc """
  Error classification contract of the streaming provider APIs: every provider
  reports a `:response_error` that echoes the logical request, carries the HTTP
  status and the provider message, and is retryable exactly for transient
  failures. Provider-specific wire formats of the failures are kept per row.
  """

  use ExUnit.Case, async: true

  import IntellectualClub.ProviderStreamHelpers
  import IntellectualClub.TestHttpServer

  alias IntellectualClub.Llm.Providers.AnthropicMessages
  alias IntellectualClub.Llm.Providers.GoogleInteractions
  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion.ChatCompletion
  alias IntellectualClub.Llm.Providers.Responses

  @overloaded "Our servers are currently overloaded. Please try again later."
  @retry_hint "An error occurred while processing your request. You can retry your request, " <>
                "or contact us through our help center if the error persists."
  @multimodal_disabled "ValueError: Received multimodal data but multimodal processing is not enabled. " <>
                         "Use --enable-multimodal flag to enable multimodal processing."
  @upstream_reset "upstream connect error or disconnect/reset before headers"

  describe "non-JSON HTTP error bodies" do
    for provider <- [:anthropic, :responses, :openrouter, :google], status <- [503, 520] do
      @provider provider
      @status status

      test "#{provider} keeps the raw body and HTTP #{status} and marks it retryable" do
        error = capture_error!(@provider, {@status, {:raw, @upstream_reset}})

        assert error.status_code == @status
        assert error.retryable == true
        assert error.error_kind == "http"
        assert error.error_text == @upstream_reset
        assert error.raw_response == %{"raw_text" => @upstream_reset, "status_code" => @status}
      end
    end
  end

  @cases [
    # Streamed error events (HTTP 200).
    {"anthropic overloaded_error events are retryable provider errors", :anthropic,
     {200,
      {:sse,
       [
         %{
           "type" => "error",
           "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
         }
       ]}},
     [status_code: nil, retryable: true, error_kind: "provider", error_text: "Overloaded"]},
    {"responses server_is_overloaded error events are retryable", :responses,
     {200,
      {:sse,
       [
         %{
           "type" => "error",
           "error" => %{
             "code" => "server_is_overloaded",
             "type" => "service_unavailable_error",
             "message" => @overloaded
           }
         }
       ]}}, [status_code: nil, retryable: true, error_text: @overloaded]},
    {"responses server errors with an explicit retry hint are retryable", :responses,
     {200,
      {:sse,
       [
         %{
           "type" => "error",
           "sequence_number" => 2,
           "error" => %{
             "code" => "server_error",
             "type" => "server_error",
             "message" => @retry_hint,
             "param" => nil
           }
         }
       ]}},
     [
       status_code: nil,
       retryable: true,
       error_text: @retry_hint,
       raw_response: {:path, ["sequence_number"], 2}
     ]},
    {"responses overloaded response.failed events are retryable", :responses,
     {200,
      {:sse,
       [
         %{
           "type" => "response.failed",
           "response" => %{
             "id" => "resp_failed",
             "status" => "failed",
             "error" => %{
               "code" => "server_is_overloaded",
               "type" => "service_unavailable_error",
               "message" => @overloaded
             }
           }
         }
       ]}}, [status_code: nil, retryable: true, error_text: @overloaded]},
    {"responses error events with code 520 are retryable HTTP 520", :responses,
     {200,
      {:sse,
       [%{"type" => "error", "error" => %{"code" => 520, "message" => "Unknown upstream error"}}]}},
     [status_code: 520, retryable: true, error_text: "Unknown upstream error"]},
    {"openrouter error chunks with code 520 are retryable HTTP 520", :openrouter,
     {200, {:sse, [%{"error" => %{"code" => 520, "message" => "Unknown upstream error"}}]}},
     [status_code: 520, retryable: true, error_text: "Unknown upstream error"]},
    {"openrouter error chunks prefer metadata raw text over the generic message", :openrouter,
     {200,
      {:sse,
       [
         %{
           "error" => %{
             "code" => 429,
             "message" => "Provider returned error",
             "metadata" => %{
               "raw" => "deepseek/deepseek-v4-pro is temporarily rate-limited upstream."
             }
           }
         }
       ]}},
     [
       status_code: 429,
       retryable: true,
       error_text: "deepseek/deepseek-v4-pro is temporarily rate-limited upstream."
     ]},
    {"google error events with code 520 are retryable HTTP 520", :google,
     {200,
      {:sse,
       [
         %{
           "event_type" => "error",
           "error" => %{"code" => 520, "message" => "Unknown upstream error"}
         }
       ]}}, [status_code: 520, retryable: true, error_text: "Unknown upstream error"]},
    {"google high-demand error events are retryable", :google,
     {200,
      {:sse,
       [
         %{
           "event_type" => "error",
           "error" => %{
             "message" =>
               "gemini-3.5-flash is currently experiencing high demand. Please try again later.",
             "code" => "api_error"
           }
         }
       ]}},
     [
       status_code: nil,
       retryable: true,
       error_text: {:contains, "high demand"},
       raw_response: {:path, ["error", "code"], "api_error"}
     ]},
    # JSON (or event-formatted) HTTP error bodies.
    {"openrouter HTTP errors prefer metadata raw text over the generic message", :openrouter,
     {429,
      {:json,
       %{
         "error" => %{
           "code" => 429,
           "message" => "Provider returned error",
           "metadata" => %{"raw" => "Provider quota is temporarily exhausted."}
         }
       }}},
     [status_code: 429, retryable: true, error_text: "Provider quota is temporarily exhausted."]},
    {"google quota errors are retryable and keep the raw response", :google,
     {429,
      {:json, %{"error" => %{"code" => "resource_exhausted", "message" => "Quota exceeded."}}}},
     [
       status_code: 429,
       retryable: true,
       error_text: "Quota exceeded.",
       raw_response: {:path, ["status_code"], 429}
     ]},
    {"google high-demand HTTP 500 errors are retryable by message", :google,
     {500,
      {:raw,
       "event: error\ndata: " <>
         Jason.encode!(%{
           "error" => %{
             "message" =>
               "gemini-3.5-flash is currently experiencing high demand, spikes in demand are usually temporary. Please try again later.",
             "code" => "api_error"
           },
           "event_type" => "error"
         })}},
     [
       status_code: 500,
       retryable: true,
       error_text: {:contains, "high demand"},
       raw_response: {:path, ["status_code"], 500},
       raw_response: {:path, ["raw_text"], {:contains, "try again later"}}
     ]},
    {"google generic HTTP 500 errors are not retryable", :google,
     {500,
      {:json, %{"error" => %{"message" => "Internal server error.", "code" => "api_error"}}}},
     [
       status_code: 500,
       retryable: false,
       error_text: "Internal server error.",
       raw_response: {:path, ["status_code"], 500}
     ]}
  ]

  nvidia_cases =
    for status <- [500, 520] do
      {"nvidia HTTP #{status} JSON errors are retryable only for transient statuses", :nvidia,
       {status,
        {:json,
         %{
           "error" => %{
             "code" => status,
             "message" => @multimodal_disabled,
             "type" => "internal_server_error"
           }
         }}},
       [
         provider: :nvidia_build_chat_completion,
         status_code: status,
         retryable: status == 520,
         error_text: @multimodal_disabled
       ]}
    end

  @cases @cases ++ nvidia_cases

  describe "provider error payloads" do
    for {name, provider, response, expected} <- @cases do
      @provider provider
      @response response
      @expected expected

      test name do
        error = capture_error!(@provider, @response)

        for {field, expected} <- @expected do
          assert_field(error, field, expected)
        end
      end
    end
  end

  defp assert_field(error, :raw_response, {:path, path, expected}),
    do: assert_value(get_in(error.raw_response, path), expected, [:raw_response | path])

  defp assert_field(error, field, expected),
    do: assert_value(Map.fetch!(error, field), expected, [field])

  defp assert_value(actual, {:contains, text}, path),
    do: assert(is_binary(actual) and actual =~ text, "#{inspect(path)}: #{inspect(actual)}")

  defp assert_value(actual, expected, path),
    do: assert(actual == expected, "#{inspect(path)}: #{inspect(actual)} != #{inspect(expected)}")

  # Starts a scripted server answering the provider endpoint once and returns
  # the error event; `run_and_capture_error!/2` checks the echoed request.
  defp capture_error!(provider, {status, body}) do
    {module, path, server_opts} = endpoint(provider)

    {base_url, _agent} =
      start_scripted_server!(%{path => [{status, chunks(provider, body)}]}, server_opts)

    run_and_capture_error!(module, opts(provider, base_url))
  end

  defp endpoint(:anthropic), do: {AnthropicMessages.Api, "/messages", record: :request}
  defp endpoint(:responses), do: {Responses.Api, "/responses", []}
  defp endpoint(:google), do: {GoogleInteractions.Api, "/interactions", json_errors()}
  defp endpoint(:openrouter), do: {ChatCompletion, "/chat/completions", json_errors()}
  defp endpoint(:nvidia), do: {NvidiaBuildChatCompletion, "/chat/completions", json_errors()}

  defp json_errors, do: [record: :request, error_content_type: "application/json"]

  defp chunks(_provider, {:raw, text}), do: [text]
  defp chunks(_provider, {:json, body}), do: [Jason.encode!(body)]
  defp chunks(:anthropic, {:sse, events}), do: anthropic_sse_chunks(events)
  defp chunks(:google, {:sse, events}), do: google_sse_chunks(events)
  defp chunks(_provider, {:sse, events}), do: sse_chunks(events)

  defp opts(:nvidia, base_url) do
    %{
      context: %{
        provider_type: NvidiaBuildChatCompletion.type(),
        provider_base_url: base_url,
        provider_api_key: "test-key"
      },
      request_payload: NvidiaBuildChatCompletion.prepare_request(chat_payload(), %{}),
      timeout_ms: provider_deadline_ms()
    }
  end

  defp opts(provider, base_url) do
    %{
      base_url: base_url,
      api_key: "test-key",
      request_payload: payload(provider),
      timeout_ms: provider_deadline_ms(),
      connect_timeout_ms: provider_deadline_ms()
    }
  end

  defp payload(:anthropic) do
    %{
      "model" => "claude-sonnet-4-20250514",
      "anthropic_version" => "2025-01-01",
      "anthropic_beta" => ["beta-a"],
      "max_tokens" => 128,
      "messages" => []
    }
  end

  defp payload(:responses), do: %{"model" => "gpt-4.1", "input" => []}

  defp payload(:google),
    do: %{"model" => "gemini-3.5-flash", "input" => "Hello", "stream" => true, "store" => false}

  defp payload(:openrouter), do: chat_payload()

  defp chat_payload do
    %{
      "model" => "deepseek/deepseek-v4-pro",
      "messages" => [%{"role" => "user", "content" => "Hello"}]
    }
  end
end
