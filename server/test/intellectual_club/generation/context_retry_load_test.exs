defmodule IntellectualClub.Generation.ContextRetryLoadTest do
  @moduledoc """
  Regression tests for retry context loading.
  """

  use IntellectualClub.DataCase, async: false

  require Ash.Query

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.LinkedForkCleanup
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Context
  alias IntellectualClub.Generation.Lease
  alias IntellectualClub.Generation.Persistence
  alias IntellectualClub.Generation.StepRequests

  test "prepare_retry/2 selects the last step and reconstructs its bounded request window" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor, "Retry last step context")
    {message, _steps} = create_retryable_assistant_message_with_steps!(chat, actor, :error, 3)

    {context, queries} =
      capture_repo_queries(fn ->
        {:ok, context} = Context.prepare_retry(message.id, actor: actor)
        context
      end)

    assert context.initial_step_sequence == 3

    assert get_in(context.request_payload, ["messages", Access.at(0), "content"]) ==
             "hello step 3"

    assert context.request_payload["temperature"] == 0
    assert context.request_payload["reasoning"] == %{"effort" => "low"}

    assert_bounded_retry_request_queries(queries)
  end

  test "prepare_retry/2 selects the requested step and reconstructs its bounded request window" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor, "Retry from step context")

    {message, [_step_1, step_2, _step_3]} =
      create_retryable_assistant_message_with_steps!(chat, actor, :done, 3)

    {context, queries} =
      capture_repo_queries(fn ->
        {:ok, context} =
          Context.prepare_retry(message.id,
            actor: actor,
            step_id: step_2.id,
            allowed_statuses: [:done, :error, :canceled]
          )

        context
      end)

    assert context.initial_step_sequence == 2

    assert get_in(context.request_payload, ["messages", Access.at(0), "content"]) ==
             "hello step 2"

    assert_bounded_retry_request_queries(queries)
  end

  test "replace_steps_for_retry!/4 filters the retry range in SQL without loading raw payloads" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor, "Retry replacement load")

    {message, [_step_1, _step_2, step_3]} =
      create_retryable_assistant_message_with_steps!(chat, actor, :error, 3)

    request = StepRequests.request_for_step!(step_3.id, actor: actor)

    assert {:ok, reservation} = Lease.reserve(message.id)

    {claim, queries} =
      capture_repo_queries(fn ->
        Lease.claim_and_run_with_chat(
          reservation,
          chat.id,
          [:error],
          fn operation, fenced ->
            Persistence.replace_steps_for_retry!(message.id, 3, request, [], operation,
              lease: fenced
            )
          end,
          with_lock_scope: fn callback ->
            LinkedForkCleanup.with_scope({:steps, message.id, 3}, actor, callback)
          end
        )
      end)

    assert {:ok, {fenced, new_step_id}} = claim
    assert :ok = Lease.release(fenced)

    assert is_integer(new_step_id)

    step_select_query =
      Enum.find(queries, fn query ->
        String.starts_with?(query, "SELECT") and
          String.contains?(query, ~s(FROM "chat_message_steps")) and
          String.contains?(query, ~s("sequence" >=))
      end)

    assert is_binary(step_select_query)
    refute step_select_query =~ ~s("raw_request")
    refute step_select_query =~ ~s("raw_response")

    replacement =
      ChatMessageStep
      |> Ash.Query.filter(id == ^new_step_id)
      |> Ash.Query.select([:id, :sequence, :status])
      |> Ash.read_one!(actor: actor)

    assert replacement.sequence == 3
    assert replacement.status == :waiting_provider
    assert StepRequests.request_for_step!(replacement.id, actor: actor) == request
  end

  test "prepare_retry reconstructs a patch without hydrating or rewriting either step" do
    %{user: actor} = user_fixture()
    chat = create_chat!(actor, "Compact retry")
    {message, [first]} = create_retryable_assistant_message_with_steps!(chat, actor, :error, 1)
    base = StepRequests.request_for_step!(first.id, actor: actor)
    request = Map.put(base, "temperature", 0.75)

    encoded =
      StepRequests.create_attributes(request,
        sequence: 2,
        previous_step: first,
        previous_request: base
      )

    assert encoded.request_mode == :patch

    second =
      ChatMessageStep
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(encoded, %{chat_message_id: message.id, sequence: 2, status: :error}),
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert {:ok, context} = Context.prepare_retry(message.id, actor: actor)
    assert context.step_id == second.id
    assert context.request_payload == request

    saved =
      Ash.get!(ChatMessageStep, second.id,
        actor: actor,
        load: [:raw_request, :request_mode, :request_patch]
      )

    assert saved.raw_request == %{}
    assert saved.request_mode == :patch
    assert saved.request_patch == encoded.request_patch
    assert StepRequests.request_for_step!(first.id, actor: actor) == base
  end

  defp create_chat!(actor, _title) do
    Chat
    |> Ash.Changeset.for_create(
      :create,
      %{note: ""},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_retryable_assistant_message_with_steps!(chat, actor, status, step_count)
       when is_integer(step_count) and step_count > 0 do
    {:ok, user_message} = Threads.add_message_to_end(chat, :user, "hello", actor: actor)

    assistant_message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{
          chat_id: chat.id,
          role: :assistant,
          parent_id: user_message.id,
          status: status,
          error_detail: if(status == :error, do: "boom", else: nil),
          token_count: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    steps =
      Enum.map(1..step_count, fn sequence ->
        ChatMessageStep
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_id: assistant_message.id,
            sequence: sequence,
            status: retryable_step_status(status),
            raw_request: %{
              "model" => "demo-model",
              "metadata" => %{"padding" => String.duplicate("x", 2_000)},
              "temperature" => 0,
              "reasoning" => %{"effort" => "low"},
              "messages" => [
                %{"role" => "user", "content" => "hello step #{sequence}"}
              ],
              "stream" => true
            },
            raw_response: %{"step" => sequence},
            response_final: status == :done and sequence == step_count
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)
      end)

    {assistant_message, steps}
  end

  defp retryable_step_status(:generating), do: :waiting_provider
  defp retryable_step_status(status), do: status

  defp capture_repo_queries(fun) when is_function(fun, 0) do
    test_pid = self()
    handler_id = "context-retry-load-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:intellectual_club, :repo, :query],
        [:intellectual_club, :postgres_repo, :query]
      ],
      fn _event_name, _measurements, metadata, pid ->
        query =
          case Map.get(metadata, :query) do
            query when is_binary(query) -> query
            query -> IO.iodata_to_binary(query)
          end

        send(pid, {:repo_query, query})
      end,
      test_pid
    )

    try do
      result = fun.()
      {result, flush_repo_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp flush_repo_queries(acc) do
    receive do
      {:repo_query, query} -> flush_repo_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_bounded_retry_request_queries(queries) when is_list(queries) do
    step_queries =
      Enum.filter(queries, fn query ->
        String.starts_with?(query, "SELECT") and
          String.contains?(query, ~s(FROM "chat_message_steps"))
      end)

    [selected_step | _] = step_queries
    refute selected_step =~ ~s("raw_request")
    refute selected_step =~ ~s("raw_response")

    assert [request_query] = Enum.filter(step_queries, &String.contains?(&1, ~s("raw_request")))
    assert request_query =~ ~s("request_patch")
    assert request_query =~ ~s("sequence" >=)
    assert request_query =~ ~s("sequence" <=)
    refute Enum.any?(step_queries, &String.contains?(&1, ~s("raw_response")))
  end
end
