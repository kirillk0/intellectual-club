defmodule IntellectualClub.Generation.ContextRetryLoadTest do
  @moduledoc """
  Regression tests for retry context loading.
  """

  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Context

  test "prepare_retry/2 loads only the last step raw request for retry-last-step" do
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

    assert_single_retry_step_query(queries)
  end

  test "prepare_retry/2 loads only the selected step raw request for retry-from-step" do
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

    assert_single_retry_step_query(queries)
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

  defp assert_single_retry_step_query(queries) when is_list(queries) do
    step_queries =
      Enum.filter(queries, fn query ->
        String.contains?(query, ~s(FROM "chat_message_steps"))
      end)

    assert length(step_queries) == 1

    [step_query] = step_queries

    assert step_query =~ ~s("raw_request")
    refute step_query =~ ~s("raw_response")
  end
end
