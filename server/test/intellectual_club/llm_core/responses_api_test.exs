defmodule IntellectualClub.LlmCore.ResponsesApiTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.LlmCore.ResponsesApi

  @base_opts %{
    base_url: "http://127.0.0.1:9",
    api_key: "test-key",
    model_name: "gpt-4.1",
    timeout_ms: 200,
    connect_timeout_ms: 200
  }

  test "forces store=false and adds empty instructions when missing" do
    error =
      run_and_capture_error!(
        Map.put(@base_opts, :request_payload, %{
          "model" => "gpt-4.1",
          "input" => []
        })
      )

    assert error.raw_request["store"] == false
    assert error.raw_request["instructions"] == ""
  end

  test "preserves provided instructions while forcing store=false" do
    error =
      run_and_capture_error!(
        Map.put(@base_opts, :request_payload, %{
          "model" => "gpt-4.1",
          "input" => [],
          "instructions" => "You are a careful assistant.",
          "store" => true
        })
      )

    assert error.raw_request["store"] == false
    assert error.raw_request["instructions"] == "You are a careful assistant."
  end

  defp run_and_capture_error!(opts) when is_map(opts) do
    parent = self()

    :ok =
      ResponsesApi.stream_generate(opts, fn event ->
        send(parent, {:provider_event, event})
      end)

    assert_receive {:provider_event, {:response_error, error}}, 2_000
    error
  end
end
