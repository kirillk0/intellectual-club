defmodule IntellectualClub.Generation.WorkerUsageCostTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.Worker
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Llm.LlmUsageRecord
  alias IntellectualClub.TestSupport.UsageCostAdapter

  require Ash.Query

  test "materializes manual trace cost in the step and usage record without changing raw usage" do
    %{actor: actor, chat: chat, assistant_message: message, step_id: step_id} =
      create_generation!()

    run_worker!(actor, chat, message, step_id, :trace, %{
      input_tokens: 1_000_000,
      cached_input_tokens: 400_000,
      output_tokens: 250_000
    })

    step = load_only_step!(message.id, actor)
    usage_record = load_usage_record!(step_id, actor)

    assert step.cost == 3.4
    assert usage_record.cost == 3.4

    assert usage_record.raw_usage == %{
             "input_tokens" => 1_000_000,
             "cached_input_tokens" => 400_000,
             "output_tokens" => 250_000
           }
  end

  test "keeps provider cost zero from terminal metadata ahead of manual pricing" do
    provider_usage = %{
      input_tokens: 1_000_000,
      cached_input_tokens: 400_000,
      output_tokens: 250_000,
      cost: "0"
    }

    %{actor: actor, chat: chat, assistant_message: message, step_id: step_id} =
      create_generation!()

    run_worker!(actor, chat, message, step_id, :meta, provider_usage)

    step = load_only_step!(message.id, actor)
    usage_record = load_usage_record!(step_id, actor)

    assert step.cost == 0.0
    assert usage_record.cost == 0.0
    assert usage_record.raw_usage["cost"] == "0"
  end

  test "persists manual cost for provider errors" do
    usage = %{input_tokens: 1_000_000, cached_input_tokens: 400_000, output_tokens: 250_000}

    %{actor: actor, chat: chat, assistant_message: message, step_id: step_id} =
      create_generation!()

    run_worker!(actor, chat, message, step_id, :meta, usage, :error)

    step = load_only_step!(message.id, actor)
    usage_record = load_usage_record!(step_id, actor)

    assert step.status == :error
    assert step.cost == 3.4
    assert usage_record.status == :error
    assert usage_record.cost == 3.4
  end

  test "persists manual cost when a generation is canceled after usage" do
    usage = %{input_tokens: 1_000_000, cached_input_tokens: 400_000, output_tokens: 250_000}

    %{actor: actor, chat: chat, assistant_message: message, step_id: step_id} =
      create_generation!()

    run_worker!(actor, chat, message, step_id, :trace, usage, :wait)

    step = load_only_step!(message.id, actor)
    usage_record = load_usage_record!(step_id, actor)

    assert step.status == :canceled
    assert step.cost == 3.4
    assert usage_record.status == :canceled
    assert usage_record.cost == 3.4
  end

  defp create_generation! do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Usage cost provider",
          type: :demo,
          auth_method: :api_key,
          base_url: "http://localhost",
          api_key: "test"
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
          model_name: "usage-cost-model",
          parameters: %{},
          cold_input_price_per_million_tokens: 2.0,
          cached_input_price_per_million_tokens: 0.5,
          output_price_per_million_tokens: 8.0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{note: "", llm_configuration_id: configuration.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "Price this", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :create_generating_assistant,
        %{
          chat_id: chat.id,
          parent_id: user_message.id,
          llm_configuration_id: configuration.id,
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    raw_request = %{"model" => "usage-cost-model", "input" => []}
    step_id = Persistence.ensure_step_started!(assistant_message.id, raw_request)

    %{actor: actor, chat: chat, assistant_message: assistant_message, step_id: step_id}
  end

  defp run_worker!(
         actor,
         chat,
         message,
         step_id,
         usage_delivery,
         usage,
         terminal_mode \\ :complete
       ) do
    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    context = %{
      owner_id: actor.id,
      chat_id: chat.id,
      message_id: message.id,
      step_id: step_id,
      provider_type: "test",
      adapter_module: UsageCostAdapter,
      request_payload: %{"model" => "usage-cost-model", "input" => []},
      timeout_ms: 1_000,
      chunk_delay_ms: 0,
      cold_input_price_per_million_tokens: 2.0,
      cached_input_price_per_million_tokens: 0.5,
      output_price_per_million_tokens: 8.0,
      usage_delivery: usage_delivery,
      test_usage: usage,
      terminal_mode: terminal_mode,
      test_pid: self()
    }

    pid = start_supervised!({Worker, %{context: context}})
    monitor_ref = Process.monitor(pid)
    message_id = message.id

    case terminal_mode do
      :complete ->
        assert_receive {:done, ^message_id}, 2_000

      :error ->
        assert_receive {:error, ^message_id, "Priced provider error"}, 2_000

      :wait ->
        assert_receive {:usage_cost_adapter_ready, _stream_task}, 2_000
        Worker.cancel(pid)
    end

    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}, 2_000
  end

  defp load_only_step!(message_id, actor) do
    message = Ash.get!(ChatMessage, message_id, actor: actor, load: [:steps])
    assert [step] = message.steps
    step
  end

  defp load_usage_record!(step_id, actor) do
    LlmUsageRecord
    |> Ash.Query.filter(chat_message_step_id_snapshot == ^step_id)
    |> Ash.read_one!(actor: actor)
  end
end
