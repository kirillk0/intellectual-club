defmodule IntellectualClub.Generation.AutoRetryTest do
  @moduledoc """
  Transient provider failures are persisted as durable error steps and the
  Worker retries the same request in a new step after the configured backoff.
  """
  use IntellectualClub.DataCase, async: false

  import IntellectualClub.Test.GenerationRuntime

  alias IntellectualClub.Chat.{ChatMessage, Threads}
  alias IntellectualClub.Generation.StepRequests
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor

  @steps_load [steps: [:raw_request, :raw_response, items: [:contents]]]

  setup do
    put_app_env(:generation_auto_retry_backoff_ms, [0, 0, 60_000])
    put_app_env(:generation_auto_retry_jitter_ratio, 0.0)
    IntellectualClub.Llm.Auth.OpenAIOAuthCache.clear()
    :ok
  end

  describe "transient provider failures" do
    test "transport failures are preserved as durable error steps before each retry" do
      %{context: context, actor: actor} =
        start_provider_generation!(%{base_url: "http://127.0.0.1:9"}, "Please fail on transport")

      message = wait_for_retry_errors!(context.message_id, actor, 3)
      steps = ordered_steps(message)
      retry_error_texts = steps |> Enum.take(3) |> Enum.map(&single_error_item_text!/1)
      latest_step = List.last(steps)

      assert Enum.map(steps, & &1.sequence) == [1, 2, 3, 4]
      assert Enum.map(steps, & &1.status) == [:error, :error, :error, :waiting_provider]
      requests = StepRequests.requests_for_steps!(steps, actor: actor)

      assert Enum.map(steps, &Map.fetch!(requests, &1.id)) ==
               List.duplicate(context.request_payload, 4)

      assert Enum.all?(steps, &is_nil(&1.raw_response))

      for {text, attempt} <- Enum.with_index(retry_error_texts, 1) do
        assert text =~ "Transient provider error on attempt #{attempt}."
      end

      assert Enum.at(retry_error_texts, 0) =~ "Retrying."
      assert Enum.at(retry_error_texts, 1) =~ "Retrying."
      assert Enum.at(retry_error_texts, 2) =~ "Retrying in 60 seconds."
      assert latest_step.id != context.step_id
      assert message.status == :generating
      assert message.error_detail == nil
      cancel_and_wait!(context.message_id, actor)
    end

    test "OAuth refresh transport errors retry through the common path" do
      attempts = :counters.new(1, [])

      put_app_env(:openai_oauth_req_options,
        plug: fn conn ->
          :counters.add(attempts, 1, 1)
          Req.Test.transport_error(conn, :timeout)
        end
      )

      %{context: context, actor: actor} =
        start_provider_generation!(
          %{
            auth_method: :openai_oauth_refresh_token,
            base_url: "https://api.openai.com/v1",
            api_key: nil,
            oauth_refresh_token: "rt_retry_transport_#{System.unique_integer([:positive])}"
          },
          "Please fail OAuth refresh"
        )

      message = wait_for_retry_errors!(context.message_id, actor, 3)
      steps = ordered_steps(message)
      retry_error_texts = steps |> Enum.take(3) |> Enum.map(&single_error_item_text!/1)

      assert Enum.map(steps, & &1.sequence) == [1, 2, 3, 4]
      assert Enum.map(steps, & &1.status) == [:error, :error, :error, :waiting_provider]
      assert :counters.get(attempts, 1) == 3

      for {text, attempt} <- Enum.with_index(retry_error_texts, 1) do
        assert text =~ "Transient provider error on attempt #{attempt}."
        assert text =~ "OAuth token refresh failed"
      end

      assert message.error_detail == nil
      assert message.status == :generating
      cancel_and_wait!(context.message_id, actor)
    end

    for status <- [429, 520] do
      @tag status: status
      test "an HTTP #{status} retry error step is kept when a later attempt succeeds",
           %{status: status} do
        raw_response = %{
          "error" => %{
            "code" => status,
            "message" => "Provider returned error",
            "metadata" => %{
              "raw" => "Upstream provider is temporarily rate-limited",
              "provider_name" => "Test Provider"
            }
          },
          "status_code" => status
        }

        script = fn
          1 ->
            [
              {:text, :answer, "Partial text that must not be persisted."},
              {:error,
               %{
                 retryable: status == 429,
                 error_kind: "http",
                 status_code: status,
                 error_text: "Upstream provider is temporarily rate-limited",
                 raw_response: raw_response
               }}
            ]

          _attempt ->
            [
              {:text, :answer, "Recovered answer."},
              {:complete,
               %{
                 raw_response: %{"id" => "resp_retry_success", "output" => []},
                 usage: %{input_tokens: 12, output_tokens: 3}
               }}
            ]
        end

        fixture =
          generation_fixture!(
            prompt: "Please recover after retry",
            context: [
              test_script: script,
              cold_input_price_per_million_tokens: 2.0,
              cached_input_price_per_million_tokens: 0.5,
              output_price_per_million_tokens: 4.0
            ]
          )

        start_worker!(fixture)
        message = wait_for_status!(fixture.message.id, fixture.actor, :done)
        steps = ordered_steps(message)

        assert :counters.get(fixture.context.test_attempts, 1) == 2
        assert message.error_detail == nil
        assert Enum.map(steps, & &1.sequence) == [1, 2]
        assert Enum.map(steps, & &1.status) == [:error, :done]
        assert_in_delta Enum.at(steps, 1).cost, 0.000036, 1.0e-12
        assert Enum.at(steps, 0).raw_response == raw_response

        retry_text = single_error_item_text!(Enum.at(steps, 0))
        assert retry_text =~ "Transient provider error on attempt 1."
        assert retry_text =~ "Upstream provider is temporarily rate-limited"
        refute retry_text =~ "Partial text that must not be persisted."
        assert answer_item_text(Enum.at(steps, 1)) == "Recovered answer."
      end
    end
  end

  describe "backoff" do
    test "the last configured retry backoff repeats for later attempts" do
      put_app_env(:generation_auto_retry_backoff_ms, [0, 20])

      fixture =
        generation_fixture!(
          context: [
            test_script: fn attempt ->
              [{:error, %{error_text: "Temporary network outage on attempt #{attempt}"}}]
            end
          ]
        )

      start_worker!(fixture)
      message = wait_for_retry_errors!(fixture.message.id, fixture.actor, 3)
      retry_steps = message |> ordered_steps() |> Enum.take(3)
      assert :counters.get(fixture.context.test_attempts, 1) >= 3
      metadata = Enum.map(retry_steps, &retry_error_metadata!/1)
      assert Enum.map(metadata, & &1["attempt"]) == [1, 2, 3]
      assert Enum.map(metadata, & &1["retry_delay_ms"]) == [0, 20, 20]
      cancel_and_wait!(fixture.message.id, fixture.actor)
    end
  end

  # A chat generation started by GenerationSupervisor against a real Responses
  # provider configuration (`provider_attrs` over an API-key provider).
  defp start_provider_generation!(provider_attrs, prompt) do
    %{user: actor} = user_fixture()

    configuration =
      create_configuration!(actor, %{
        model_name: "gpt-4.1-mini",
        timeout_seconds: 1,
        provider_attrs: Map.merge(%{type: :responses}, provider_attrs)
      })

    chat = create_chat!(actor, %{llm_configuration_id: configuration.id})
    {:ok, _user_message} = Threads.add_message_to_end(chat, :user, prompt, actor: actor)
    {:ok, context} = GenerationSupervisor.start_generation(chat.id, actor: actor)
    %{actor: actor, context: context}
  end

  defp cancel_and_wait!(message_id, actor) do
    :ok = GenerationSupervisor.cancel_generation(message_id)
    assert wait_for_status!(message_id, actor, :canceled).status == :canceled
  end

  defp wait_for_status!(message_id, actor, wanted) do
    wait_for_message_status!(message_id, actor, wanted,
      timeout: 5_000,
      load: @steps_load,
      stop_worker: true
    )
  end

  # Waits until `count` retry error steps precede an active retry step.
  defp wait_for_retry_errors!(message_id, actor, count) do
    wait_until(
      fn ->
        message = Ash.get!(ChatMessage, message_id, actor: actor, load: @steps_load)
        steps = ordered_steps(message)

        message.status == :generating and Enum.count(steps, &retry_error_step?/1) >= count and
          length(steps) >= count + 1 and List.last(steps).status == :waiting_provider and message
      end,
      timeout: 5_000,
      interval: 20
    )
  end

  defp ordered_steps(%ChatMessage{} = message), do: Enum.sort_by(message.steps, & &1.sequence)

  defp single_error_item_text!(step) do
    assert [item] = Enum.filter(step.items, &(&1.type == :error))
    item_text(item)
  end

  defp retry_error_step?(step), do: retry_error_metadata(step) != nil

  defp retry_error_metadata!(step) do
    assert %{} = metadata = retry_error_metadata(step)
    metadata
  end

  defp retry_error_metadata(step) do
    step.items
    |> Enum.filter(&(&1.type == :error))
    |> Enum.flat_map(& &1.contents)
    |> Enum.filter(&(&1.kind == :opaque))
    |> Enum.map(& &1.content_json)
    |> Enum.find(&(is_map(&1) and &1["retryable"] == true and is_integer(&1["attempt"])))
  end

  defp answer_item_text(step) do
    step.items
    |> Enum.filter(&(&1.type == :answer))
    |> Enum.map_join("\n\n", &item_text/1)
  end
end
