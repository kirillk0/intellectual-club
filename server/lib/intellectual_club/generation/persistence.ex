defmodule IntellectualClub.Generation.Persistence do
  @moduledoc """
  Persists generation state through Ash resources in staged durable commits.

  Provider chunks remain an in-memory UI concern until the provider response is
  complete. After that point, persisted step items and raw provider output are
  the source of truth for tool execution, recovery, history, and finalization.
  """

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Generation.ToolCall
  alias IntellectualClub.Generation.ToolResult
  alias IntellectualClub.Llm.LlmUsageRecord
  alias IntellectualClub.TokenCounter

  require Ash.Query

  @opaque_sequence 10_000
  @tool_result_sequence_base 1_000_000
  @tool_result_sequence_stride 1_000
  @transaction_resources [
    ChatMessage,
    ChatMessageStep,
    ChatMessageItem,
    ChatMessageContent,
    LlmUsageRecord
  ]

  def ensure_step_started!(message_id, raw_request, opts \\ [])
      when is_integer(message_id) and is_list(opts) do
    ensure_step_started!(message_id, 1, raw_request, opts)
  end

  def ensure_step_started!(message_id, sequence, raw_request, opts)
      when is_integer(message_id) and is_integer(sequence) and is_list(opts) do
    _ = opts
    actor = actor_for_message!(message_id)

    transaction!(fn ->
      attrs = %{
        chat_message_id: message_id,
        sequence: sequence,
        status: :waiting_provider,
        raw_request: normalize_json_map(raw_request),
        raw_response: nil,
        response_final: false,
        input_tokens: nil,
        output_tokens: nil,
        cached_input_tokens: nil,
        reasoning_tokens: nil,
        cost: nil,
        first_token_at: nil,
        finished_at: nil
      }

      step =
        case get_step_by_sequence(message_id, sequence, actor) do
          nil ->
            create_step!(attrs, actor)

          %ChatMessageStep{} = step ->
            update_step!(step, Map.delete(attrs, :chat_message_id), actor)
        end

      step.id
    end)
  end

  @doc """
  Persists the completed provider step and returns the persisted tool calls.
  """
  def persist_provider_completed!(message_id, %RuntimeTrace.Step{} = runtime_step)
      when is_integer(message_id) do
    status =
      if runtime_step_has_tool_calls?(runtime_step) do
        :waiting_tools
      else
        :done
      end

    step = persist_step_snapshot!(message_id, runtime_step, status, replace_items?: true)
    tool_calls = list_tool_calls_for_step!(step.id)

    %{step: step, tool_calls: tool_calls}
  end

  def persist_step_waiting_tools!(message_id, %RuntimeTrace.Step{} = runtime_step)
      when is_integer(message_id) do
    _ = persist_step_snapshot!(message_id, runtime_step, :waiting_tools, replace_items?: true)
    :ok
  end

  def persist_step_trace_only!(message_id, %RuntimeTrace.Step{} = runtime_step)
      when is_integer(message_id) do
    _ = persist_step_snapshot!(message_id, runtime_step, :done, replace_items?: true)
    :ok
  end

  def persist_completed!(message_id, %RuntimeTrace.Step{} = runtime_step) do
    actor = actor_for_message!(message_id)

    transaction!(fn ->
      step = persist_step_snapshot_in_transaction!(message_id, runtime_step, :done, actor)
      answer_text = RuntimeTrace.text_for_item_type(runtime_step, :answer)
      now = DateTime.utc_now()

      message_id
      |> load_message!(actor)
      |> update_message!(
        %{
          status: :done,
          error_detail: nil,
          token_count: TokenCounter.estimate(answer_text),
          finished_at: now
        },
        actor
      )

      persist_usage_record!(
        step.id,
        Map.get(RuntimeTrace.persistable(runtime_step), :usage),
        :done,
        now,
        actor
      )
    end)

    :ok
  end

  def persist_completed_from_step!(message_id, step_id)
      when is_integer(message_id) and is_integer(step_id) do
    actor = actor_for_message!(message_id)

    transaction!(fn ->
      step = load_step_with_items!(step_id, actor)
      answer_text = text_for_item_type(step, :answer)
      now = DateTime.utc_now()

      message_id
      |> load_message!(actor)
      |> update_message!(
        %{
          status: :done,
          error_detail: nil,
          token_count: TokenCounter.estimate(answer_text),
          finished_at: now
        },
        actor
      )

      update_step!(step, %{status: :done, finished_at: now}, actor)
      persist_usage_record!(step.id, nil, :done, now, actor)
    end)

    :ok
  end

  def persist_canceled!(message_id, %RuntimeTrace.Step{} = runtime_step) do
    actor = actor_for_message!(message_id)

    transaction!(fn ->
      step = persist_step_snapshot_in_transaction!(message_id, runtime_step, :canceled, actor)
      answer_text = RuntimeTrace.text_for_item_type(runtime_step, :answer)
      now = DateTime.utc_now()

      message_id
      |> load_message!(actor)
      |> update_message!(
        %{
          status: :canceled,
          token_count: TokenCounter.estimate(answer_text),
          finished_at: now
        },
        actor
      )

      persist_usage_record!(
        step.id,
        Map.get(RuntimeTrace.persistable(runtime_step), :usage),
        :canceled,
        now,
        actor
      )
    end)

    :ok
  end

  def persist_error!(message_id, %RuntimeTrace.Step{} = runtime_step, error_text) do
    actor = actor_for_message!(message_id)

    transaction!(fn ->
      step = persist_step_snapshot_in_transaction!(message_id, runtime_step, :error, actor)
      answer_text = RuntimeTrace.text_for_item_type(runtime_step, :answer)
      now = DateTime.utc_now()

      message_id
      |> load_message!(actor)
      |> update_message!(
        %{
          status: :error,
          error_detail: to_string(error_text || ""),
          token_count: TokenCounter.estimate(answer_text),
          finished_at: now
        },
        actor
      )

      persist_usage_record!(
        step.id,
        Map.get(RuntimeTrace.persistable(runtime_step), :usage),
        :error,
        now,
        actor
      )
    end)

    :ok
  end

  def persist_error_from_step!(message_id, step_id, error_text)
      when is_integer(message_id) and is_integer(step_id) do
    actor = actor_for_message!(message_id)

    transaction!(fn ->
      step = load_step_with_items!(step_id, actor)

      if step.chat_message_id != message_id do
        raise ArgumentError, "Step does not belong to message"
      end

      now = DateTime.utc_now()

      maybe_create_error_item!(step, error_text, actor)
      step = load_step_with_items!(step_id, actor)
      answer_text = text_for_item_type(step, :answer)

      message_id
      |> load_message!(actor)
      |> update_message!(
        %{
          status: :error,
          error_detail: to_string(error_text || ""),
          token_count: TokenCounter.estimate(answer_text),
          finished_at: now
        },
        actor
      )

      update_step!(step, %{status: :error, finished_at: now}, actor)
      persist_usage_record!(step.id, nil, :error, now, actor)
    end)

    :ok
  end

  def persist_retry_error_and_start_next_step!(
        message_id,
        step_id,
        raw_request,
        error_text,
        opts \\ []
      )
      when is_integer(message_id) and is_integer(step_id) and is_list(opts) do
    actor = actor_for_message!(message_id)

    transaction!(fn ->
      step = load_step_with_items!(step_id, actor)

      if step.chat_message_id != message_id do
        raise ArgumentError, "Step does not belong to message"
      end

      now = DateTime.utc_now()
      next_sequence = step.sequence + 1

      raw_request =
        case raw_request do
          value when is_map(value) and map_size(value) > 0 -> normalize_json_map(value)
          _other -> normalize_json_map(step.raw_request || %{})
        end

      replace_step_items!(step, [], actor)

      step =
        step
        |> update_step!(
          %{
            status: :error,
            raw_response: nil,
            response_final: false,
            input_tokens: nil,
            output_tokens: nil,
            cached_input_tokens: nil,
            reasoning_tokens: nil,
            cost: nil,
            first_token_at: nil,
            finished_at: now
          },
          actor
        )
        |> load_step_with_items!(actor)

      create_retry_error_item!(
        step,
        retry_error_text(error_text, opts),
        retry_error_metadata(opts),
        actor
      )

      next_step =
        case get_step_by_sequence(message_id, next_sequence, actor) do
          nil ->
            create_step!(
              %{
                chat_message_id: message_id,
                sequence: next_sequence,
                status: :waiting_provider,
                raw_request: raw_request,
                raw_response: nil,
                response_final: false,
                input_tokens: nil,
                output_tokens: nil,
                cached_input_tokens: nil,
                reasoning_tokens: nil,
                cost: nil,
                first_token_at: nil,
                finished_at: nil
              },
              actor
            )

          %ChatMessageStep{} = next_step ->
            replace_step_items!(next_step, [], actor)

            update_step!(
              next_step,
              %{
                status: :waiting_provider,
                raw_request: raw_request,
                raw_response: nil,
                response_final: false,
                input_tokens: nil,
                output_tokens: nil,
                cached_input_tokens: nil,
                reasoning_tokens: nil,
                cost: nil,
                first_token_at: nil,
                finished_at: nil
              },
              actor
            )
        end

      message_id
      |> load_message!(actor)
      |> update_message!(
        %{
          status: :generating,
          error_detail: nil,
          token_count: 0,
          finished_at: nil
        },
        actor
      )

      %{
        step_id: next_step.id,
        step_sequence: next_step.sequence,
        started_at: next_step.created_at,
        raw_request: raw_request
      }
    end)
  end

  def mark_step_done!(step_id) when is_integer(step_id) do
    actor = actor_for_step!(step_id)
    now = DateTime.utc_now()

    transaction!(fn ->
      step = load_step!(step_id, actor)
      update_step!(step, %{status: :done, finished_at: now}, actor)
      persist_usage_record!(step.id, nil, :done, now, actor)
    end)

    :ok
  end

  def persist_tool_result!(message_id, step_id, %ToolCall{} = call, result)
      when is_integer(message_id) and is_integer(step_id) do
    actor = actor_for_message!(message_id)

    transaction!(fn ->
      step = load_step_with_items!(step_id, actor)
      calls_by_item_id = persisted_tool_calls_by_item_id(step)

      call =
        case Map.get(calls_by_item_id, call.item_id) do
          %ToolCall{} = persisted -> persisted
          _other -> call
        end

      case existing_tool_result_item(step, call.item_id) do
        %ChatMessageItem{} = item ->
          item
          |> load_item_with_contents!(actor)
          |> tool_result_from_item(calls_by_item_id)

        nil ->
          result = normalize_tool_execution_result(call, result)
          sequence = tool_result_sequence(step.items || [], call)
          responses_item = responses_item_for_result(result)

          item =
            create_item!(
              %{
                chat_message_step_id: step_id,
                sequence: sequence,
                type: :tool_result,
                tool_call_item_id: call.item_id
              },
              actor
            )

          create_tool_result_contents!(item, result, responses_item, actor)
          create_artifact_items!(step_id, result, sequence + 1, actor)

          item
          |> load_item_with_contents!(actor)
          |> tool_result_from_item(calls_by_item_id)
      end
    end)
  end

  def list_missing_tool_calls!(step_id) when is_integer(step_id) do
    actor = actor_for_step!(step_id)

    step_id
    |> load_step_with_items!(actor)
    |> missing_tool_calls()
  end

  def load_step_for_followup!(step_id) when is_integer(step_id) do
    actor = actor_for_step!(step_id)
    step = load_step_with_items!(step_id, actor)
    calls_by_item_id = persisted_tool_calls_by_item_id(step)

    %{
      step: step,
      runtime_step:
        runtime_step_from_persisted_step(step, &(&1.type not in [:tool_result, :artifact])),
      tool_calls: calls_by_item_id |> Map.values() |> Enum.sort_by(& &1.sequence),
      results:
        step
        |> ordered_items()
        |> Enum.filter(&(&1.type == :tool_result))
        |> Enum.map(&tool_result_from_item(&1, calls_by_item_id))
    }
  end

  def step_tool_resume_state!(step_id) when is_integer(step_id) do
    actor = actor_for_step!(step_id)
    step = load_step_with_items!(step_id, actor)
    tool_calls = persisted_tool_calls_by_item_id(step) |> Map.values()
    missing_tool_calls = missing_tool_calls(step)

    %{
      tool_call_count: length(tool_calls),
      missing_tool_call_count: length(missing_tool_calls)
    }
  end

  def list_generating_messages_for_resume! do
    ChatMessage
    |> Ash.Query.filter(status == :generating)
    |> Ash.Query.select([:id, :owner_id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(&%{id: &1.id, owner_id: &1.owner_id})
  end

  def cancel_orphaned_generating_messages!(chat_id) when is_integer(chat_id) do
    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id and status == :generating)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false)
    |> Enum.each(&cancel_orphaned_generating_message!(&1.id))

    :ok
  end

  def cancel_orphaned_generating_message!(message_id) when is_integer(message_id) do
    actor = actor_for_message!(message_id)
    now = DateTime.utc_now()

    transaction!(fn ->
      message_id
      |> steps_for_message(actor)
      |> Enum.filter(&(&1.status in [:waiting_provider, :waiting_tools]))
      |> Enum.each(fn step ->
        update_step!(step, %{status: :canceled, finished_at: now}, actor)
      end)

      message_id
      |> load_message!(actor)
      |> update_message!(
        %{
          status: :canceled,
          error_detail: "Orphaned generation (worker not found)",
          finished_at: now
        },
        actor
      )
    end)

    :ok
  end

  def rollback_last_step_for_retry!(message_id, step_sequence)
      when is_integer(message_id) and is_integer(step_sequence) and step_sequence > 0 do
    rollback_steps_for_retry!(message_id, step_sequence)
  end

  def rollback_steps_for_retry!(message_id, from_sequence)
      when is_integer(message_id) and is_integer(from_sequence) and from_sequence > 0 do
    actor = actor_for_message!(message_id)

    transaction!(fn ->
      steps =
        message_id
        |> steps_for_message(actor)
        |> Enum.filter(&(&1.sequence >= from_sequence))
        |> Enum.sort_by(& &1.sequence, :desc)

      if steps == [] do
        raise ArgumentError, "Retry step not found"
      end

      Enum.each(steps, &Ash.destroy!(&1, actor: actor))

      message_id
      |> load_message!(actor)
      |> update_message!(
        %{
          status: :generating,
          error_detail: nil,
          token_count: 0,
          finished_at: nil
        },
        actor
      )
    end)

    :ok
  end

  defp persist_step_snapshot!(message_id, %RuntimeTrace.Step{} = runtime_step, step_status, opts)
       when is_integer(message_id) and is_list(opts) do
    actor = actor_for_message!(message_id)

    transaction!(fn ->
      persist_step_snapshot_in_transaction!(message_id, runtime_step, step_status, actor)
    end)
  end

  defp persist_step_snapshot_in_transaction!(message_id, runtime_step, step_status, actor) do
    persistable = RuntimeTrace.persistable(runtime_step)
    sequence = positive_int(Map.get(persistable, :sequence), 1)
    now = DateTime.utc_now()
    status = normalize_step_status(step_status)
    finished_at = if status in [:done, :canceled, :error], do: now, else: nil

    attrs = %{
      chat_message_id: message_id,
      sequence: sequence,
      status: status,
      raw_request: normalize_json_map(Map.get(persistable, :raw_request)),
      raw_response: normalize_optional_json(Map.get(persistable, :raw_response)),
      response_final: Map.get(persistable, :response_final, false) == true,
      input_tokens: Map.get(persistable, :input_tokens),
      output_tokens: Map.get(persistable, :output_tokens),
      cached_input_tokens: Map.get(persistable, :cached_input_tokens),
      reasoning_tokens: Map.get(persistable, :reasoning_tokens),
      cost: Map.get(persistable, :cost),
      first_token_at: Map.get(persistable, :first_token_at),
      finished_at: finished_at
    }

    step =
      case get_step_by_sequence(message_id, sequence, actor) do
        nil ->
          create_step!(attrs, actor)

        %ChatMessageStep{} = step ->
          update_step!(step, Map.delete(attrs, :chat_message_id), actor)
      end

    replace_step_items!(step, Map.get(persistable, :items, []), actor)

    persist_usage_record!(
      step.id,
      Map.get(persistable, :usage),
      status,
      finished_at || now,
      actor
    )

    load_step_with_items!(step.id, actor)
  end

  defp replace_step_items!(%ChatMessageStep{} = step, items, actor) when is_list(items) do
    step
    |> load_step_with_items!(actor)
    |> Map.get(:items, [])
    |> ordered_by_sequence()
    |> Enum.reverse()
    |> Enum.each(&Ash.destroy!(&1, actor: actor))

    normalized_items =
      items
      |> Enum.filter(&is_map/1)
      |> Enum.sort_by(&positive_int(Map.get(&1, :sequence), 0))

    {calls_by_call_id, calls_by_sequence} =
      normalized_items
      |> Enum.reject(&(normalize_item_type(Map.get(&1, :type)) == :tool_result))
      |> Enum.reduce({%{}, %{}}, fn item, {by_call_id, by_sequence} ->
        type = normalize_item_type(Map.get(item, :type))

        created =
          create_item!(
            %{
              chat_message_step_id: step.id,
              sequence: positive_int(Map.get(item, :sequence), 1),
              type: type,
              tool_call_item_id: nil
            },
            actor
          )

        create_contents!(created, Map.get(item, :contents, []), actor)

        by_sequence = Map.put(by_sequence, created.sequence, created.id)

        by_call_id =
          if type == :tool_call do
            case tool_call_identity_from_persistable_item(item) do
              "" -> by_call_id
              call_id -> Map.put(by_call_id, call_id, created.id)
            end
          else
            by_call_id
          end

        {by_call_id, by_sequence}
      end)

    normalized_items
    |> Enum.filter(&(normalize_item_type(Map.get(&1, :type)) == :tool_result))
    |> Enum.each(fn item ->
      tool_call_item_id =
        item
        |> tool_result_call_id_from_persistable_item()
        |> case do
          "" -> nil
          call_id -> Map.get(calls_by_call_id, call_id)
        end

      tool_call_item_id =
        tool_call_item_id || preceding_tool_call_item_id(item, calls_by_sequence)

      created =
        create_item!(
          %{
            chat_message_step_id: step.id,
            sequence: positive_int(Map.get(item, :sequence), 1),
            type: :tool_result,
            tool_call_item_id: tool_call_item_id
          },
          actor
        )

      create_contents!(created, Map.get(item, :contents, []), actor)
    end)

    :ok
  end

  defp create_tool_result_contents!(item, %ToolResult{} = result, responses_item, actor) do
    opaque = %{
      "tool_call_id" => result.call_id,
      "call_id" => result.call_id,
      "tool_call_item_id" => result.tool_call_item_id,
      "name" => result.name,
      "raw" => result.result_raw,
      "responses_item" => responses_item
    }

    text_content = %{
      external_id: Ash.UUID.generate(),
      sequence: 1,
      kind: :text,
      content_text: result.text,
      content_json: nil,
      file_id: nil
    }

    media_contents =
      result.media_contents
      |> Enum.map(&normalize_media_persistable_content/1)
      |> Enum.reject(&is_nil/1)

    opaque_content = %{
      external_id: Ash.UUID.generate(),
      sequence: @opaque_sequence,
      kind: :opaque,
      content_text: "",
      content_json: opaque,
      file_id: nil
    }

    create_contents!(item, [text_content | media_contents] ++ [opaque_content], actor)
  end

  defp create_artifact_items!(_step_id, %ToolResult{artifact_contents: []}, _sequence, _actor),
    do: :ok

  defp create_artifact_items!(step_id, %ToolResult{} = result, first_sequence, actor) do
    result.artifact_contents
    |> Enum.map(&normalize_media_persistable_content/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index(first_sequence)
    |> Enum.each(fn {content, item_sequence} ->
      item =
        create_item!(
          %{
            chat_message_step_id: step_id,
            sequence: item_sequence,
            type: :artifact,
            tool_call_item_id: nil
          },
          actor
        )

      create_contents!(item, [%{content | sequence: 1}], actor)
    end)
  end

  defp maybe_create_error_item!(%ChatMessageStep{} = step, error_text, actor) do
    has_error_item? =
      step
      |> ordered_items()
      |> Enum.any?(&(&1.type == :error))

    if has_error_item? do
      :ok
    else
      item =
        create_item!(
          %{
            chat_message_step_id: step.id,
            sequence: next_item_sequence(step.items || []),
            type: :error,
            tool_call_item_id: nil
          },
          actor
        )

      create_contents!(
        item,
        [
          %{
            sequence: 1,
            kind: :text,
            content_text: to_string(error_text || "")
          }
        ],
        actor
      )
    end
  end

  defp create_retry_error_item!(%ChatMessageStep{} = step, text, metadata, actor) do
    item =
      create_item!(
        %{
          chat_message_step_id: step.id,
          sequence: next_item_sequence(step.items || []),
          type: :error,
          tool_call_item_id: nil
        },
        actor
      )

    contents = [
      %{
        sequence: 1,
        kind: :text,
        content_text: to_string(text || "")
      }
    ]

    contents =
      if map_size(metadata) > 0 do
        contents ++
          [
            %{
              sequence: @opaque_sequence,
              kind: :opaque,
              content_json: metadata
            }
          ]
      else
        contents
      end

    create_contents!(item, contents, actor)
  end

  defp retry_error_text(error_text, opts) when is_list(opts) do
    attempt = Keyword.get(opts, :attempt)
    delay_ms = Keyword.get(opts, :retry_delay_ms)
    retry_in = retry_delay_text(delay_ms)
    detail = error_text |> to_string() |> String.trim()

    prefix =
      case attempt do
        value when is_integer(value) and value > 0 ->
          "Transient provider error on attempt #{value}."

        _other ->
          "Transient provider error."
      end

    suffix =
      case retry_in do
        "" -> " Retrying."
        value -> " Retrying in #{value}."
      end

    if detail == "" do
      prefix <> suffix
    else
      prefix <> suffix <> "\n\n" <> detail
    end
  end

  defp retry_delay_text(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    cond do
      delay_ms < 1000 ->
        "#{delay_ms} ms"

      rem(delay_ms, 1000) == 0 ->
        seconds = div(delay_ms, 1000)
        unit = if seconds == 1, do: "second", else: "seconds"
        "#{seconds} #{unit}"

      true ->
        seconds = Float.round(delay_ms / 1000.0, 1)
        "#{seconds} seconds"
    end
  end

  defp retry_delay_text(_delay_ms), do: ""

  defp retry_error_metadata(opts) when is_list(opts) do
    %{}
    |> maybe_put_metadata("attempt", Keyword.get(opts, :attempt))
    |> maybe_put_metadata("retry_delay_ms", Keyword.get(opts, :retry_delay_ms))
    |> maybe_put_metadata("status_code", Keyword.get(opts, :status_code))
    |> maybe_put_metadata("error_kind", Keyword.get(opts, :error_kind))
    |> maybe_put_metadata("retryable", Keyword.get(opts, :retryable))
  end

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, _key, value) when is_binary(value) and value == "", do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp create_contents!(%ChatMessageItem{} = item, contents, actor) when is_list(contents) do
    contents
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&positive_int(Map.get(&1, :sequence), 0))
    |> Enum.each(fn content ->
      attrs = %{
        chat_message_item_id: item.id,
        external_id: Map.get(content, :external_id) || Ash.UUID.generate(),
        sequence: positive_int(Map.get(content, :sequence), 1),
        kind: normalize_content_kind(Map.get(content, :kind)),
        content_text: to_string(Map.get(content, :content_text) || ""),
        content_json: normalize_optional_json(Map.get(content, :content_json)),
        file_id: Map.get(content, :file_id)
      }

      ChatMessageContent
      |> Ash.Changeset.for_create(:create, attrs, actor: actor)
      |> Ash.create!(actor: actor)
    end)
  end

  defp create_step!(attrs, actor) when is_map(attrs) do
    ChatMessageStep
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp update_step!(%ChatMessageStep{} = step, attrs, actor) when is_map(attrs) do
    step
    |> Ash.Changeset.for_update(:update, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp create_item!(attrs, actor) when is_map(attrs) do
    ChatMessageItem
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end

  defp update_message!(%ChatMessage{} = message, attrs, actor) when is_map(attrs) do
    message
    |> Ash.Changeset.for_update(:set_generation_state, attrs, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp persist_usage_record!(step_id, raw_usage, step_status, occurred_at, actor)
       when is_integer(step_id) do
    step =
      ChatMessageStep
      |> Ash.get!(step_id,
        authorize?: false,
        load: [owner: [], chat_message: [llm_configuration: [:provider]]]
      )

    message = step.chat_message
    configuration = message && message.llm_configuration

    if message && message.role == :assistant && configuration do
      provider = configuration.provider
      existing = usage_record_for_step(step_id)
      raw_usage = raw_usage || (existing && existing.raw_usage)

      attrs = %{
        usage_user_id: step.owner_id,
        usage_user_id_snapshot: step.owner_id,
        usage_username_snapshot: username_snapshot(step.owner, step.owner_id),
        configuration_owner_id: configuration.owner_id,
        configuration_owner_id_snapshot: configuration.owner_id,
        llm_configuration_id: configuration.id,
        llm_configuration_id_snapshot: configuration.id,
        llm_configuration_external_id_snapshot: configuration.external_id,
        llm_configuration_label_snapshot:
          configuration_label(configuration.model_name, configuration.note, configuration.id),
        provider_id: provider && provider.id,
        provider_id_snapshot: provider && provider.id,
        provider_name_snapshot: provider && provider.name,
        provider_type_snapshot: provider && to_string(provider.type),
        chat_id: message.chat_id,
        chat_id_snapshot: message.chat_id,
        chat_message_id: message.id,
        chat_message_id_snapshot: message.id,
        chat_message_step_id: step.id,
        chat_message_step_id_snapshot: step.id,
        step_sequence: step.sequence,
        status: normalize_step_status(step_status),
        response_final: step.response_final == true,
        occurred_at: occurred_at || DateTime.utc_now(),
        input_tokens: step.input_tokens,
        output_tokens: step.output_tokens,
        cached_input_tokens: step.cached_input_tokens,
        reasoning_tokens: step.reasoning_tokens,
        cost: step.cost,
        raw_usage: normalize_optional_json(raw_usage)
      }

      if usage_present?(attrs) do
        case existing do
          nil ->
            LlmUsageRecord
            |> Ash.Changeset.for_create(
              :create,
              Map.put(attrs, :external_id, Ash.UUID.generate()),
              actor: actor
            )
            |> Ash.create!(actor: actor)

          %LlmUsageRecord{} = record ->
            record
            |> Ash.Changeset.for_update(:update, attrs, actor: actor)
            |> Ash.update!(actor: actor)
        end
      end
    end

    :ok
  end

  defp usage_record_for_step(step_id) when is_integer(step_id) do
    LlmUsageRecord
    |> Ash.Query.filter(chat_message_step_id_snapshot == ^step_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp usage_present?(attrs) when is_map(attrs) do
    Enum.any?(
      [:input_tokens, :output_tokens, :cached_input_tokens, :reasoning_tokens, :cost],
      &(not is_nil(Map.get(attrs, &1)))
    )
  end

  defp load_message!(message_id, actor) when is_integer(message_id) do
    Ash.get!(ChatMessage, message_id, actor: actor)
  end

  defp load_step!(step_id, actor) when is_integer(step_id) do
    Ash.get!(ChatMessageStep, step_id, actor: actor)
  end

  defp load_step_with_items!(%ChatMessageStep{id: step_id}, actor) when is_integer(step_id) do
    load_step_with_items!(step_id, actor)
  end

  defp load_step_with_items!(step_id, actor) when is_integer(step_id) do
    ChatMessageStep
    |> Ash.get!(step_id,
      actor: actor,
      load: [
        items: [
          :tool_call_item_id,
          contents: [
            :file_id,
            file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]
          ]
        ]
      ]
    )
  end

  defp load_item_with_contents!(%ChatMessageItem{} = item, actor) do
    Ash.load!(
      item,
      [
        :tool_call_item_id,
        contents: [
          :file_id,
          file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]
        ]
      ],
      actor: actor
    )
  end

  defp get_step_by_sequence(message_id, sequence, actor) do
    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^message_id and sequence == ^sequence)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: actor)
  end

  defp steps_for_message(message_id, actor) do
    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^message_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.read!(actor: actor)
  end

  defp list_tool_calls_for_step!(step_id) when is_integer(step_id) do
    actor = actor_for_step!(step_id)

    step_id
    |> load_step_with_items!(actor)
    |> persisted_tool_calls_by_item_id()
    |> Map.values()
    |> Enum.sort_by(& &1.sequence)
  end

  defp missing_tool_calls(%ChatMessageStep{} = step) do
    calls_by_item_id = persisted_tool_calls_by_item_id(step)

    answered =
      step
      |> ordered_items()
      |> Enum.filter(&(&1.type == :tool_result))
      |> Enum.map(& &1.tool_call_item_id)
      |> Enum.filter(&is_integer/1)
      |> MapSet.new()

    calls_by_item_id
    |> Map.values()
    |> Enum.reject(&MapSet.member?(answered, &1.item_id))
    |> Enum.sort_by(& &1.sequence)
  end

  defp persisted_tool_calls_by_item_id(%ChatMessageStep{} = step) do
    step
    |> ordered_items()
    |> Enum.filter(&(&1.type == :tool_call))
    |> Enum.flat_map(&tool_call_from_item/1)
    |> Map.new(&{&1.item_id, &1})
  end

  defp tool_call_from_item(%ChatMessageItem{} = item) do
    opaque = latest_opaque_content(item)
    raw = tool_call_raw_from_opaque(opaque)

    call_id =
      [
        Map.get(opaque, "tool_call_id"),
        Map.get(opaque, "call_id"),
        Map.get(raw, "call_id"),
        Map.get(raw, "id")
      ]
      |> Enum.find("", &present_string?/1)
      |> to_string()
      |> String.trim()

    call_id = if call_id == "", do: "item_#{item.id}", else: call_id

    name =
      [
        Map.get(opaque, "name"),
        Map.get(raw, "name"),
        get_in(raw, ["function", "name"])
      ]
      |> Enum.find("", &present_string?/1)
      |> to_string()
      |> String.trim()

    args_value =
      Map.get(raw, "arguments") ||
        get_in(raw, ["function", "arguments"]) ||
        Map.get(opaque, "arguments")

    args = parse_tool_args(args_value)

    if name != "" do
      [
        %ToolCall{
          item_id: item.id,
          step_id: item.chat_message_step_id,
          sequence: item.sequence,
          call_id: call_id,
          name: name,
          args: args,
          raw: ensure_tool_call_raw(raw, call_id, name, args_value, args)
        }
      ]
    else
      []
    end
  end

  defp tool_result_from_item(%ChatMessageItem{} = item, calls_by_item_id)
       when is_map(calls_by_item_id) do
    opaque = latest_opaque_content(item)
    call = Map.get(calls_by_item_id, item.tool_call_item_id)
    responses_item = Map.get(opaque, "responses_item")

    call_id =
      [
        call && call.call_id,
        Map.get(opaque, "tool_call_id"),
        Map.get(opaque, "call_id"),
        is_map(responses_item) && Map.get(responses_item, "call_id")
      ]
      |> Enum.find("", &present_string?/1)
      |> to_string()
      |> String.trim()

    %ToolResult{
      item_id: item.id,
      step_id: item.chat_message_step_id,
      tool_call_item_id: item.tool_call_item_id,
      sequence: item.sequence,
      call_id: call_id,
      name: (call && call.name) || to_string(Map.get(opaque, "name") || ""),
      args: (call && call.args) || %{},
      text: item_text(item),
      raw: (call && call.raw) || %{},
      result_raw: normalize_json_map(Map.get(opaque, "raw")),
      responses_item: if(is_map(responses_item), do: Map.new(responses_item), else: nil),
      media_contents: media_contents_for_item(item),
      artifact_contents: []
    }
  end

  defp normalize_tool_execution_result(%ToolCall{} = call, %ToolResult{} = result) do
    %ToolResult{
      result
      | step_id: call.step_id,
        tool_call_item_id: call.item_id,
        call_id: call.call_id,
        name: call.name,
        args: call.args || %{},
        raw: call.raw || %{}
    }
  end

  defp normalize_tool_execution_result(%ToolCall{} = call, result) when is_map(result) do
    %ToolResult{
      step_id: call.step_id,
      tool_call_item_id: call.item_id,
      call_id: call.call_id,
      name: call.name,
      args: call.args || %{},
      raw: call.raw || %{},
      text: to_string(Map.get(result, :text, Map.get(result, "text", "")) || ""),
      result_raw:
        normalize_json_map(Map.get(result, :result_raw, Map.get(result, "result_raw", %{}))),
      media_contents:
        normalize_list(Map.get(result, :media_contents, Map.get(result, "media_contents", []))),
      artifact_contents:
        normalize_list(
          Map.get(result, :artifact_contents, Map.get(result, "artifact_contents", []))
        )
    }
  end

  defp existing_tool_result_item(%ChatMessageStep{} = step, tool_call_item_id)
       when is_integer(tool_call_item_id) do
    step
    |> ordered_items()
    |> Enum.find(&(&1.type == :tool_result and &1.tool_call_item_id == tool_call_item_id))
  end

  defp existing_tool_result_item(_step, _tool_call_item_id), do: nil

  defp responses_item_for_result(%ToolResult{responses_item: %{} = responses_item}),
    do: responses_item

  defp responses_item_for_result(%ToolResult{} = result) do
    %{
      "type" => "function_call_output",
      "id" => "fco_" <> Ash.UUID.generate(),
      "call_id" => result.call_id,
      "output" => result.text
    }
  end

  defp runtime_step_from_persisted_step(%ChatMessageStep{} = step, include_item?) do
    Enum.reduce(ordered_items(step), persisted_step_header(step), fn item, runtime_step ->
      if include_item?.(item) do
        key = "db:#{item.id}"

        runtime_step =
          RuntimeTrace.apply_event(runtime_step, {:ensure_item, key, item.type, item.sequence})

        item
        |> ordered_contents()
        |> Enum.reduce(runtime_step, fn content, acc ->
          case content.kind do
            :text ->
              RuntimeTrace.apply_event(
                acc,
                {:set_text, key, item.type, content.sequence,
                 to_string(content.content_text || "")}
              )

            :opaque ->
              RuntimeTrace.apply_event(
                acc,
                {:set_opaque, key, item.type, content.sequence,
                 normalize_optional_json(content.content_json)}
              )

            :media ->
              RuntimeTrace.apply_event(
                acc,
                {:set_media, key, item.type, content.sequence, media_content_payload(content)}
              )

            _other ->
              acc
          end
        end)
      else
        runtime_step
      end
    end)
  end

  defp persisted_step_header(%ChatMessageStep{} = step) do
    RuntimeTrace.new_step(
      id: step.id,
      sequence: step.sequence,
      started_at: step.created_at,
      status: step.status,
      raw_request: step.raw_request || %{},
      raw_response: step.raw_response,
      response_final: step.response_final,
      input_tokens: step.input_tokens,
      output_tokens: step.output_tokens,
      cached_input_tokens: step.cached_input_tokens,
      reasoning_tokens: step.reasoning_tokens,
      cost: step.cost,
      first_token_at: step.first_token_at
    )
  end

  defp runtime_step_has_tool_calls?(%RuntimeTrace.Step{} = runtime_step) do
    runtime_step.items_by_key
    |> Map.values()
    |> Enum.any?(&match?(%RuntimeTrace.Item{type: :tool_call}, &1))
  end

  defp latest_opaque_content(%ChatMessageItem{} = item) do
    item
    |> ordered_contents()
    |> Enum.reverse()
    |> Enum.find_value(%{}, fn
      %{kind: :opaque, content_json: %{} = json} -> normalize_tool_call_map(json)
      _other -> nil
    end)
  end

  defp tool_call_raw_from_opaque(%{} = opaque) do
    case Map.get(opaque, "raw") do
      %{} = raw ->
        normalize_tool_call_map(raw)

      _other ->
        case Map.get(opaque, "responses_item") do
          %{} = raw -> normalize_tool_call_map(raw)
          _other -> normalize_tool_call_map(opaque)
        end
    end
  end

  defp tool_call_raw_from_opaque(_other), do: %{}

  defp tool_call_identity_from_persistable_item(item) when is_map(item) do
    item
    |> persistable_opaque_payloads()
    |> Enum.find_value("", fn opaque ->
      raw = tool_call_raw_from_opaque(opaque)

      [
        Map.get(opaque, "tool_call_id"),
        Map.get(opaque, "call_id"),
        Map.get(raw, "call_id"),
        Map.get(raw, "id")
      ]
      |> Enum.find("", &present_string?/1)
    end)
    |> to_string()
    |> String.trim()
  end

  defp tool_result_call_id_from_persistable_item(item) when is_map(item) do
    item
    |> persistable_opaque_payloads()
    |> Enum.find_value("", fn opaque ->
      responses_item = Map.get(opaque, "responses_item")

      [
        Map.get(opaque, "tool_call_id"),
        Map.get(opaque, "call_id"),
        is_map(responses_item) && Map.get(responses_item, "call_id")
      ]
      |> Enum.find("", &present_string?/1)
    end)
    |> to_string()
    |> String.trim()
  end

  defp persistable_opaque_payloads(item) when is_map(item) do
    item
    |> Map.get(:contents, [])
    |> normalize_list()
    |> Enum.sort_by(&positive_int(Map.get(&1, :sequence), 0))
    |> Enum.flat_map(fn content ->
      if normalize_content_kind(Map.get(content, :kind)) == :opaque and
           is_map(Map.get(content, :content_json)) do
        [normalize_tool_call_map(Map.get(content, :content_json))]
      else
        []
      end
    end)
  end

  defp preceding_tool_call_item_id(item, calls_by_sequence) when is_map(calls_by_sequence) do
    item_sequence = positive_int(Map.get(item, :sequence), 0)

    calls_by_sequence
    |> Enum.filter(fn {sequence, _id} -> sequence < item_sequence end)
    |> Enum.max_by(fn {sequence, _id} -> sequence end, fn -> nil end)
    |> case do
      {_sequence, id} -> id
      nil -> nil
    end
  end

  defp text_for_item_type(%ChatMessageStep{} = step, item_type) when is_atom(item_type) do
    step
    |> ordered_items()
    |> Enum.filter(&(&1.type == item_type))
    |> Enum.map(&item_text/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp item_text(%ChatMessageItem{} = item) do
    item
    |> ordered_contents()
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join("", &to_string(&1.content_text || ""))
  end

  defp media_contents_for_item(%ChatMessageItem{} = item) do
    item
    |> ordered_contents()
    |> Enum.filter(&(&1.kind == :media))
    |> Enum.map(&media_content_payload/1)
  end

  defp media_content_payload(content) do
    file = Map.get(content, :file)

    %{
      external_id: content.external_id,
      sequence: content.sequence,
      kind: :media,
      file_id: content.file_id,
      file: file_payload(file)
    }
  end

  defp normalize_media_persistable_content(content) when is_map(content) do
    file_id = Map.get(content, :file_id, Map.get(content, "file_id"))
    sequence = Map.get(content, :sequence, Map.get(content, "sequence", 1))

    if is_integer(file_id) do
      %{
        external_id:
          Map.get(content, :external_id, Map.get(content, "external_id")) || Ash.UUID.generate(),
        sequence: positive_int(sequence, 1),
        kind: :media,
        content_text: "",
        content_json: nil,
        file_id: file_id
      }
    else
      nil
    end
  end

  defp normalize_media_persistable_content(_content), do: nil

  defp file_payload(%{} = file) do
    %{
      "id" => Map.get(file, :id),
      "external_id" => Map.get(file, :external_id),
      "filename" => Map.get(file, :filename),
      "mime_type" => Map.get(file, :mime_type),
      "size_bytes" => Map.get(file, :size_bytes),
      "sha256" => Map.get(file, :sha256)
    }
  end

  defp file_payload(_file), do: %{}

  defp ordered_items(%ChatMessageStep{} = step), do: ordered_by_sequence(step.items || [])
  defp ordered_contents(%ChatMessageItem{} = item), do: ordered_by_sequence(item.contents || [])

  defp next_item_sequence(items) when is_list(items) do
    items
    |> Enum.map(&positive_int(Map.get(&1, :sequence), 0))
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp tool_result_sequence(items, %ToolCall{sequence: call_sequence})
       when is_list(items) and is_integer(call_sequence) and call_sequence > 0 do
    candidate = @tool_result_sequence_base + call_sequence * @tool_result_sequence_stride

    if sequence_used?(items, candidate) do
      next_item_sequence(items)
    else
      candidate
    end
  end

  defp tool_result_sequence(items, _call) when is_list(items), do: next_item_sequence(items)

  defp sequence_used?(items, sequence) when is_list(items) and is_integer(sequence) do
    Enum.any?(items, &(Map.get(&1, :sequence) == sequence))
  end

  defp ordered_by_sequence(values) when is_list(values) do
    Enum.sort_by(values, &positive_int(Map.get(&1, :sequence), 0))
  end

  defp parse_tool_args(%{} = args), do: args

  defp parse_tool_args(args) when is_binary(args) do
    text = String.trim(args)

    if text == "" do
      %{}
    else
      case Jason.decode(text) do
        {:ok, %{} = obj} -> obj
        _other -> %{}
      end
    end
  end

  defp parse_tool_args(_other), do: %{}

  defp ensure_tool_call_raw(raw, call_id, name, args_value, args)
       when is_binary(call_id) and is_binary(name) do
    raw = normalize_tool_call_map(raw)
    arguments = tool_call_arguments_text(args_value, args)

    cond do
      is_map(Map.get(raw, "function")) or Map.get(raw, "type") == "function" ->
        function =
          raw
          |> Map.get("function", %{})
          |> normalize_tool_call_map()
          |> Map.put("name", name)
          |> Map.put("arguments", arguments)

        raw
        |> Map.put("id", call_id)
        |> Map.put("type", "function")
        |> Map.put("function", function)

      present_string?(Map.get(raw, "call_id")) or present_string?(Map.get(raw, "name")) or
          Map.get(raw, "type") == "function_call" ->
        raw
        |> Map.put("id", Map.get(raw, "id") || call_id)
        |> Map.put("type", "function_call")
        |> Map.put("call_id", call_id)
        |> Map.put("name", name)
        |> Map.put("arguments", arguments)

      true ->
        %{
          "id" => call_id,
          "type" => "function_call",
          "call_id" => call_id,
          "name" => name,
          "arguments" => arguments
        }
    end
  end

  defp tool_call_arguments_text(value, %{} = args) do
    cond do
      is_binary(value) and String.trim(value) != "" -> value
      is_map(value) and map_size(value) > 0 -> Jason.encode!(value)
      map_size(args) > 0 -> Jason.encode!(args)
      true -> "{}"
    end
  end

  defp normalize_tool_call_map(%{} = value) do
    Map.new(value, fn {key, nested} ->
      {to_string(key), normalize_tool_call_value(nested)}
    end)
  end

  defp normalize_tool_call_map(_other), do: %{}

  defp normalize_tool_call_value(%{} = value), do: normalize_tool_call_map(value)

  defp normalize_tool_call_value(list) when is_list(list),
    do: Enum.map(list, &normalize_tool_call_value/1)

  defp normalize_tool_call_value(value), do: value

  defp normalize_step_status(value)
       when value in [:waiting_provider, :waiting_tools, :done, :canceled, :error],
       do: value

  defp normalize_step_status(value) when is_binary(value), do: value |> String.to_existing_atom()

  defp normalize_item_type(value)
       when value in [
              :input,
              :reasoning,
              :answer,
              :tool_call,
              :tool_result,
              :artifact,
              :error,
              :other
            ],
       do: value

  defp normalize_item_type(value) when is_binary(value) do
    case value do
      "input" -> :input
      "reasoning" -> :reasoning
      "answer" -> :answer
      "tool_call" -> :tool_call
      "tool_result" -> :tool_result
      "artifact" -> :artifact
      "error" -> :error
      _other -> :other
    end
  end

  defp normalize_item_type(_other), do: :other

  defp normalize_content_kind(value) when value in [:text, :opaque, :media], do: value
  defp normalize_content_kind("opaque"), do: :opaque
  defp normalize_content_kind("media"), do: :media
  defp normalize_content_kind(_other), do: :text

  defp normalize_json_map(%{} = value), do: Map.new(value)
  defp normalize_json_map(nil), do: %{}
  defp normalize_json_map(value) when is_list(value), do: %{"items" => value}
  defp normalize_json_map(value), do: %{"raw" => value}

  defp normalize_optional_json(nil), do: nil
  defp normalize_optional_json(%{} = value), do: Map.new(value)
  defp normalize_optional_json(value) when is_list(value), do: %{"items" => value}
  defp normalize_optional_json(value), do: %{"raw" => value}

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_value), do: []

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_other), do: false

  defp actor_for_message!(message_id) when is_integer(message_id) do
    message = Ash.get!(ChatMessage, message_id, authorize?: false)
    %User{id: message.owner_id}
  end

  defp actor_for_step!(step_id) when is_integer(step_id) do
    step = Ash.get!(ChatMessageStep, step_id, authorize?: false)
    %User{id: step.owner_id}
  end

  defp transaction!(fun) when is_function(fun, 0) do
    case Ash.transaction(@transaction_resources, fun) do
      {:ok, result} -> result
      {:error, error} -> raise inspect(error)
    end
  end

  defp username_snapshot(%User{username: username}, _user_id)
       when is_binary(username) and username != "",
       do: username

  defp username_snapshot(_user, user_id), do: "User ##{user_id}"

  defp configuration_label(model_name, note, id) do
    model_name =
      case model_name do
        value when is_binary(value) and value != "" -> value
        _other -> "Configuration ##{id}"
      end

    note =
      case note do
        value when is_binary(value) -> String.trim(value)
        _other -> ""
      end

    if note == "", do: model_name, else: "#{model_name} (#{note})"
  end
end
