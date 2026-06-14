defmodule IntellectualClub.Generation.AutoRetryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Generation.Worker
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider

  defmodule AlwaysFailingAdapter do
    @moduledoc false

    def stream_generate(%{context: context, request_payload: request_payload}, emit) do
      attempt = Agent.get_and_update(context.attempts, fn value -> {value + 1, value + 1} end)

      emit.(
        {:response_error,
         %{
           retryable: true,
           error_kind: "network",
           status_code: 503,
           error_text: "Temporary network outage on attempt #{attempt}",
           raw_request: request_payload
         }}
      )

      :ok
    end
  end

  defmodule FlakyAdapter do
    @moduledoc false

    def stream_generate(%{context: context, request_payload: request_payload}, emit) do
      attempt = Agent.get_and_update(context.attempts, fn value -> {value + 1, value + 1} end)

      if attempt == 1 do
        emit.(
          {:trace, {:set_text, "answer", :answer, 1, "Partial text that must not be persisted."}}
        )

        emit.(
          {:response_error,
           %{
             retryable: true,
             error_kind: "network",
             status_code: 503,
             error_text: "Temporary network outage",
             raw_request: request_payload
           }}
        )
      else
        emit.({:trace, {:set_text, "answer", :answer, 1, "Recovered answer."}})

        emit.(
          {:response_complete,
           %{
             raw_request: request_payload,
             raw_response: %{"id" => "resp_retry_success", "output" => []},
             usage: %{"input_tokens" => 12, "output_tokens" => 3}
           }}
        )
      end

      :ok
    end
  end

  setup do
    previous_backoff = Application.get_env(:intellectual_club, :generation_auto_retry_backoff_ms)
    previous_jitter = Application.get_env(:intellectual_club, :generation_auto_retry_jitter_ratio)

    Application.put_env(:intellectual_club, :generation_auto_retry_backoff_ms, [0, 0, 60_000])
    Application.put_env(:intellectual_club, :generation_auto_retry_jitter_ratio, 0.0)

    table = :ic_openai_oauth_token_cache

    if :ets.whereis(table) != :undefined do
      :ets.delete_all_objects(table)
    end

    on_exit(fn ->
      restore_env(:generation_auto_retry_backoff_ms, previous_backoff)
      restore_env(:generation_auto_retry_jitter_ratio, previous_jitter)
    end)

    :ok
  end

  test "generation preserves transient provider retry failures as durable error steps" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Retry provider",
          type: :responses,
          auth_method: :api_key,
          base_url: "http://127.0.0.1:9",
          api_key: "test-key"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "gpt-4.1-mini",
          note: "",
          parameters: %{},
          timeout_seconds: 1
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: "",
          llm_configuration_id: configuration.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Please fail on transport", actor: actor)

    {:ok, context} = GenerationSupervisor.start_generation(chat.id, actor: actor)

    message = wait_for_retry_error_count!(context.message_id, actor, 3, 12_000)

    steps = ordered_steps(message)
    retry_steps = Enum.take(steps, 3)
    retry_error_texts = Enum.map(retry_steps, &single_error_item_text!/1)
    latest_step = List.last(steps)

    assert Enum.map(steps, & &1.sequence) == [1, 2, 3, 4]
    assert Enum.map(steps, & &1.status) == [:error, :error, :error, :waiting_provider]
    assert Enum.map(steps, & &1.raw_request) == List.duplicate(context.request_payload, 4)

    assert Enum.at(retry_error_texts, 0) =~ "Transient provider error on attempt 1."
    assert Enum.at(retry_error_texts, 0) =~ "Retrying."
    assert Enum.at(retry_error_texts, 1) =~ "Transient provider error on attempt 2."
    assert Enum.at(retry_error_texts, 1) =~ "Retrying."
    assert Enum.at(retry_error_texts, 2) =~ "Transient provider error on attempt 3."
    assert Enum.at(retry_error_texts, 2) =~ "Retrying in 60 seconds."
    assert latest_step.id != context.step_id
    assert latest_step.status == :waiting_provider
    assert message.status == :generating
    assert message.error_detail == nil

    :ok = GenerationSupervisor.cancel_generation(context.message_id)

    canceled = wait_for_status!(context.message_id, actor, [:canceled], 4_000)
    assert canceled.status == :canceled
  end

  test "generation retries OAuth refresh transport errors through common retry path" do
    %{user: actor} = user_fixture()

    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    previous_req_options = Application.get_env(:intellectual_club, :openai_oauth_req_options)

    Application.put_env(:intellectual_club, :openai_oauth_req_options,
      plug: fn conn ->
        Agent.update(attempts, &(&1 + 1))
        Req.Test.transport_error(conn, :timeout)
      end
    )

    on_exit(fn ->
      if is_nil(previous_req_options) do
        Application.delete_env(:intellectual_club, :openai_oauth_req_options)
      else
        Application.put_env(:intellectual_club, :openai_oauth_req_options, previous_req_options)
      end
    end)

    oauth_refresh_token =
      "rt_retry_transport_" <> Integer.to_string(System.unique_integer([:positive]))

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "OAuth retry provider",
          type: :responses,
          auth_method: :openai_oauth_refresh_token,
          base_url: "https://api.openai.com/v1",
          oauth_refresh_token: oauth_refresh_token
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "gpt-4.1-mini",
          note: "",
          parameters: %{},
          timeout_seconds: 1
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: "",
          llm_configuration_id: configuration.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Please fail OAuth refresh", actor: actor)

    {:ok, context} = GenerationSupervisor.start_generation(chat.id, actor: actor)

    message = wait_for_retry_error_count!(context.message_id, actor, 3, 12_000)

    steps = ordered_steps(message)
    retry_steps = Enum.take(steps, 3)
    retry_error_texts = Enum.map(retry_steps, &single_error_item_text!/1)

    assert Enum.map(steps, & &1.sequence) == [1, 2, 3, 4]
    assert Enum.map(steps, & &1.status) == [:error, :error, :error, :waiting_provider]
    assert Agent.get(attempts, & &1) == 3
    assert Enum.at(retry_error_texts, 0) =~ "Transient provider error on attempt 1."
    assert Enum.at(retry_error_texts, 0) =~ "OAuth token refresh failed"
    assert Enum.at(retry_error_texts, 1) =~ "Transient provider error on attempt 2."
    assert Enum.at(retry_error_texts, 1) =~ "OAuth token refresh failed"
    assert Enum.at(retry_error_texts, 2) =~ "Transient provider error on attempt 3."
    assert Enum.at(retry_error_texts, 2) =~ "OAuth token refresh failed"
    assert message.error_detail == nil
    assert message.status == :generating

    :ok = GenerationSupervisor.cancel_generation(context.message_id)

    canceled = wait_for_status!(context.message_id, actor, [:canceled], 4_000)
    assert canceled.status == :canceled
  end

  test "generation keeps retry error step when a later attempt succeeds" do
    %{user: actor} = user_fixture()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: ""
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} =
      Threads.add_message_to_end(chat, :user, "Please recover after retry", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => "Please recover after retry"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(assistant_message.id, raw_request)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: assistant_message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: FlakyAdapter,
      request_payload: raw_request,
      timeout_ms: 1_000,
      chunk_delay_ms: 0,
      attempts: attempts
    }

    {:ok, _pid} = Worker.start_link(%{context: context})

    message = wait_for_status!(assistant_message.id, actor, [:done], 12_000)
    steps = ordered_steps(message)

    assert Agent.get(attempts, & &1) == 2
    assert message.status == :done
    assert message.error_detail == nil
    assert Enum.map(steps, & &1.sequence) == [1, 2]
    assert Enum.map(steps, & &1.status) == [:error, :done]

    retry_text = single_error_item_text!(Enum.at(steps, 0))
    final_answer_text = answer_item_text(Enum.at(steps, 1))

    assert retry_text =~ "Transient provider error on attempt 1."
    assert retry_text =~ "Temporary network outage"
    refute retry_text =~ "Partial text that must not be persisted."
    assert final_answer_text == "Recovered answer."
  end

  test "generation repeats the last configured retry backoff for later attempts" do
    Application.put_env(:intellectual_club, :generation_auto_retry_backoff_ms, [0, 250])

    %{user: actor} = user_fixture()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    %{message: assistant_message} = start_custom_worker!(actor, AlwaysFailingAdapter, attempts)

    message = wait_for_retry_error_count!(assistant_message.id, actor, 3, 4_000)
    steps = ordered_steps(message)
    retry_steps = Enum.take(steps, 3)

    assert Agent.get(attempts, & &1) >= 3

    assert Enum.map(retry_steps, &retry_error_metadata!/1) |> Enum.map(&Map.get(&1, "attempt")) ==
             [1, 2, 3]

    assert Enum.map(retry_steps, &retry_error_metadata!/1)
           |> Enum.map(&Map.get(&1, "retry_delay_ms")) == [0, 250, 250]

    :ok = GenerationSupervisor.cancel_generation(assistant_message.id)

    canceled = wait_for_status!(assistant_message.id, actor, [:canceled], 4_000)
    assert canceled.status == :canceled
  end

  defp start_custom_worker!(actor, adapter, attempts) do
    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          note: ""
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} =
      Threads.add_message_to_end(chat, :user, "Please fail transiently", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{chat_id: chat.id, parent_id: user_message.id, token_count: 0},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{
      "model" => "test-model",
      "messages" => [%{"role" => "user", "content" => "Please fail transiently"}],
      "stream" => true
    }

    step_id = Persistence.ensure_step_started!(assistant_message.id, raw_request)

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: assistant_message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: adapter,
      request_payload: raw_request,
      timeout_ms: 1_000,
      chunk_delay_ms: 0,
      attempts: attempts
    }

    {:ok, _pid} = Worker.start_link(%{context: context})

    %{chat: chat, message: assistant_message}
  end

  defp wait_for_status!(message_id, actor, wanted, timeout_ms)
       when is_integer(message_id) and is_list(wanted) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_status(message_id, actor, wanted, deadline)
  end

  defp do_wait_for_status(message_id, actor, wanted, deadline) do
    message =
      Ash.get!(ChatMessage, message_id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    if message.status in wanted do
      wait_for_generation_worker_to_stop!(message_id)
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        # Avoid hammering the shared sandbox connection while generation runs in
        # other processes.
        Process.sleep(100)
        do_wait_for_status(message_id, actor, wanted, deadline)
      else
        flunk("Generation did not reach expected status")
      end
    end
  end

  defp wait_for_retry_error_count!(message_id, actor, expected_count, timeout_ms)
       when is_integer(message_id) and is_integer(expected_count) and expected_count > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_retry_error_count(message_id, actor, expected_count, deadline)
  end

  defp do_wait_for_retry_error_count(message_id, actor, expected_count, deadline) do
    message =
      Ash.get!(ChatMessage, message_id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    steps = ordered_steps(message)
    retry_count = Enum.count(steps, &retry_error_step?/1)
    latest_step = List.last(steps)

    if message.status == :generating and retry_count >= expected_count and
         active_retry_step?(latest_step) do
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(50)
        do_wait_for_retry_error_count(message_id, actor, expected_count, deadline)
      else
        flunk("Generation did not persist expected retry errors")
      end
    end
  end

  defp wait_for_generation_worker_to_stop!(message_id) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    do_wait_for_generation_worker_to_stop!(message_id, deadline)
  end

  defp do_wait_for_generation_worker_to_stop!(message_id, deadline) do
    if GenerationSupervisor.get_generation_state(message_id) == :not_found do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        do_wait_for_generation_worker_to_stop!(message_id, deadline)
      else
        flunk("Generation worker did not stop before timeout")
      end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:intellectual_club, key)
  defp restore_env(key, value), do: Application.put_env(:intellectual_club, key, value)

  defp ordered_steps(%ChatMessage{} = message) do
    message.steps
    |> List.wrap()
    |> Enum.sort_by(& &1.sequence)
  end

  defp single_error_item_text!(step) do
    step.items
    |> List.wrap()
    |> Enum.filter(&(&1.type == :error))
    |> case do
      [item] -> item_text(item)
      other -> flunk("Expected exactly one error item, got #{length(other)}")
    end
  end

  defp retry_error_step?(step) do
    step.items
    |> List.wrap()
    |> Enum.any?(fn item ->
      item.type == :error and
        item.contents
        |> List.wrap()
        |> Enum.any?(fn content ->
          content.kind == :opaque and retry_error_metadata?(content.content_json)
        end)
    end)
  end

  defp retry_error_metadata!(step) do
    step.items
    |> List.wrap()
    |> Enum.filter(&(&1.type == :error))
    |> Enum.flat_map(fn item ->
      item.contents
      |> List.wrap()
      |> Enum.filter(&(&1.kind == :opaque))
      |> Enum.map(& &1.content_json)
    end)
    |> Enum.find(&retry_error_metadata?/1)
    |> case do
      %{} = metadata -> metadata
      _other -> flunk("Expected retry error metadata")
    end
  end

  defp retry_error_metadata?(%{} = metadata) do
    Map.get(metadata, "retryable") == true and is_integer(Map.get(metadata, "attempt"))
  end

  defp retry_error_metadata?(_metadata), do: false

  defp active_retry_step?(%{status: status}),
    do: status in [:waiting_provider, "waiting_provider"]

  defp active_retry_step?(_step), do: false

  defp answer_item_text(step) do
    step.items
    |> List.wrap()
    |> Enum.filter(&(&1.type == :answer))
    |> Enum.map_join("\n\n", &item_text/1)
  end

  defp item_text(item) do
    item.contents
    |> List.wrap()
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map_join("", &to_string(&1.content_text || ""))
  end
end
