defmodule IntellectualClub.Generation.UsageCostTest do
  @moduledoc """
  Step cost resolution (`IntellectualClub.Generation.UsageCost`) and its
  materialization by the generation worker into steps and usage records.
  """

  use IntellectualClub.DataCase, async: false

  import IntellectualClub.ProviderStreamHelpers, only: [provider_deadline_ms: 0]

  require Ash.Query

  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Generation.{Lease, Persistence, UsageCost, Worker}
  alias IntellectualClub.Llm.LlmUsageRecord
  alias IntellectualClub.TestSupport.UsageCostAdapter

  @pricing %{
    cold_input_price_per_million_tokens: 2.0,
    cached_input_price_per_million_tokens: 0.5,
    output_price_per_million_tokens: 8.0
  }

  @usage %{input_tokens: 1_000_000, cached_input_tokens: 400_000, output_tokens: 250_000}

  describe "UsageCost.resolve/2" do
    for {name, usage, pricing_changes, expected} <- [
          {"prefers a valid provider cost, even zero, to manual pricing",
           %{input_tokens: 1_000_000, output_tokens: 1_000_000, cost: "0"}, %{}, 0.0},
          {"returns a numeric provider cost without token counts", %{cost: 1.25}, %{}, 1.25},
          {"falls back to manual pricing for an invalid provider cost",
           %{input_tokens: 1_000_000, output_tokens: 0, cost: "not-a-number"}, %{}, 2.0},
          {"prices cold input and output when no cache is read",
           %{input_tokens: 1_000_000, output_tokens: 250_000}, %{}, 4.0},
          {"prices cache reads separately and leaves cache creation in cold input",
           %{
             input_tokens: 1_000_000,
             cached_input_tokens: 400_000,
             cache_creation_input_tokens: 300_000,
             cache_write_cost: 999.0,
             output_tokens: 250_000
           }, %{}, 3.4},
          {"clamps negative cached input tokens to zero",
           %{input_tokens: 1_000_000, cached_input_tokens: -10, output_tokens: 0}, %{}, 2.0},
          {"clamps cached input tokens to the total input",
           %{input_tokens: 1_000_000, cached_input_tokens: 2_000_000, output_tokens: 0}, %{},
           0.5},
          {"requires complete pricing", %{input_tokens: 10, output_tokens: 5},
           %{output_price_per_million_tokens: nil}, nil},
          {"requires output tokens", %{input_tokens: 10}, %{}, nil},
          {"requires input tokens", %{output_tokens: 5}, %{}, nil},
          {"requires integer cached input tokens",
           %{input_tokens: 10, cached_input_tokens: "5", output_tokens: 5}, %{}, nil}
        ] do
      test name do
        pricing = Map.merge(@pricing, unquote(Macro.escape(pricing_changes)))
        assert UsageCost.resolve(unquote(Macro.escape(usage)), pricing) == unquote(expected)
      end
    end
  end

  describe "Worker cost materialization" do
    for {name, delivery, usage, terminal_mode, status, cost} <- [
          {"stores manual cost of trace usage in the step and usage record", :trace, @usage,
           :complete, :done, 3.4},
          {"keeps a zero provider cost from terminal metadata ahead of manual pricing", :meta,
           Map.put(@usage, :cost, "0"), :complete, :done, 0.0},
          {"stores manual cost for provider errors", :meta, @usage, :error, :error, 3.4},
          {"stores manual cost when the generation is canceled after usage", :trace, @usage,
           :wait, :canceled, 3.4}
        ] do
      test name do
        usage = unquote(Macro.escape(usage))
        %{actor: actor, chat: chat, message: message, step_id: step_id} = create_generation!()

        run_worker!(
          actor,
          chat,
          message,
          step_id,
          unquote(delivery),
          usage,
          unquote(terminal_mode)
        )

        assert [step] = Ash.get!(ChatMessage, message.id, actor: actor, load: [:steps]).steps

        usage_record =
          LlmUsageRecord
          |> Ash.Query.filter(chat_message_step_id_snapshot == ^step_id)
          |> Ash.read_one!(actor: actor)

        assert step.status == unquote(status)
        assert step.cost == unquote(cost)
        assert usage_record.status == unquote(status)
        assert usage_record.cost == unquote(cost)

        assert usage_record.raw_usage ==
                 Map.new(usage, fn {key, value} -> {to_string(key), value} end)
      end
    end
  end

  defp create_generation! do
    %{user: actor} = user_fixture()

    configuration =
      create_configuration!(
        actor,
        Map.merge(@pricing, %{model_name: "usage-cost-model", note: nil})
      )

    chat = create_chat!(actor, llm_configuration_id: configuration.id)

    message =
      create_generating_message!(actor, chat,
        user_text: "Price this",
        llm_configuration_id: configuration.id,
        token_count: 0
      )

    raw_request = %{"model" => "usage-cost-model", "input" => []}
    step_id = Persistence.ensure_step_started!(message.id, raw_request)

    %{actor: actor, chat: chat, message: message, step_id: step_id}
  end

  defp run_worker!(actor, chat, message, step_id, usage_delivery, usage, terminal_mode) do
    Phoenix.PubSub.subscribe(IntellectualClub.PubSub, "chat:#{chat.id}")

    context =
      Map.merge(@pricing, %{
        owner_id: actor.id,
        chat_id: chat.id,
        message_id: message.id,
        step_id: step_id,
        provider_type: "test",
        adapter_module: UsageCostAdapter,
        request_payload: %{"model" => "usage-cost-model", "input" => []},
        timeout_ms: provider_deadline_ms(),
        chunk_delay_ms: 0,
        usage_delivery: usage_delivery,
        test_usage: usage,
        terminal_mode: terminal_mode,
        test_pid: self()
      })

    assert {:ok, lease} = Lease.acquire(message.id)

    pid =
      start_supervised!(%{
        id: {Worker, message.id, make_ref()},
        start: {Worker, :start_link, [%{context: context, lease: lease, lease_owner: self()}]},
        restart: :temporary
      })

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
end
