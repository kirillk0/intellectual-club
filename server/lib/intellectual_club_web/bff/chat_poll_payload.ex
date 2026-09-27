defmodule IntellectualClubWeb.Bff.ChatPollPayload do
  @moduledoc """
  Revision-aware polling with separately cached completed display and step details.

  Every request supplies a freshly authorized message and reads authorized lean
  metadata. IDs and update timestamps detect edits, replacement and deletion, not
  just new items. No raw request/response is selected, cached or serialized here.
  """
  require Ash.Query

  alias IntellectualClub.Chat.{ChatMessageContent, ChatMessageItem, ChatMessageStep, SubchatCosts}
  alias IntellectualClubWeb.Bff.{ChatBranchPayload, PollCache, Serializer}

  @step_fields ~w(id chat_message_id sequence created_at updated_at finished_at status response_final input_tokens output_tokens cached_input_tokens reasoning_tokens first_token_at last_token_at cost)a
  @item_fields ~w(id chat_message_step_id sequence type tool_call_item_id updated_at)a
  @content_fields ~w(id chat_message_item_id sequence kind file_id updated_at)a
  @retry_fields ~w(retry_error_count latest_retry_error_text latest_retry_error_at latest_retry_error_step_sequence)a

  @doc "Cheap cursor polling; revisions describe metadata, never accumulated text."
  def cursor_response(message, actor, runtime, params, meta) do
    persisted_revision = persisted_revision(message)
    base = Map.merge(meta, runtime_metadata(message, runtime))
    costs = SubchatCosts.for_messages([message], actor)
    stream = stream(runtime)

    {summary, view_revision, revision} =
      cursor_revisions(runtime, persisted_revision, base, costs.revision, params)

    cond do
      params["content_revision"] == persisted_revision and
        params["view_revision"] == view_revision and not Map.get(stream, :reset, false) ->
        if params["revision"] == revision and base.availability != "busy" do
          :unchanged
        else
          {:ok,
           base
           |> Map.merge(%{
             revision: revision,
             view_revision: view_revision,
             content_revision: persisted_revision,
             runtime_cursor: Map.get(stream, :cursor),
             runtime_summary: summary
           })
           |> put_delta(stream)}
        end

      true ->
        # Full projection is paid for only by a reader crossing a UI boundary.
        runtime =
          if runtime_step(runtime) && not Map.get(stream, :reset, false) do
            IntellectualClub.Generation.Supervisor.poll_generation(message.id, %{},
              protocol: :cursor
            )
          else
            runtime
          end

        data = metadata(message, actor, runtime, true)
        runtime = reconcile_cursor_runtime(runtime, data.runtime_step)
        stream = stream(runtime)
        base = Map.merge(meta, runtime_metadata(message, runtime))

        {_summary, view_revision, revision} =
          cursor_revisions(runtime, persisted_revision, base, costs.revision, params)

        selection = selection(data, params["working_step_id"])

        persisted =
          if params["content_revision"] != persisted_revision,
            do: completed_payload(message, actor, data)

        retry_summary =
          PollCache.fetch(cache_key(message, actor, :retry_summary), data.revision, fn ->
            (persisted || completed_payload(message, actor, data)).working
            |> Map.take(@retry_fields)
          end)

        payload =
          Map.merge(base, %{
            revision: revision,
            view_revision: view_revision,
            content_revision: persisted_revision,
            runtime_cursor: Map.get(stream, :cursor),
            runtime_targets: Map.get(stream, :targets, []),
            working: data.summaries |> Serializer.working_summary() |> Map.merge(retry_summary),
            usage:
              Serializer.usage_summary(data.summaries,
                subchat_cost: Map.get(costs.costs_by_message_id, message.id)
              )
          })

        payload =
          cond do
            persisted ->
              Map.put(
                payload,
                :content,
                Serializer.merge_runtime_message_content(
                  persisted.content,
                  data.runtime_step,
                  message.role
                )
              )

            data.runtime_step ->
              payload
              |> Map.put(
                :runtime_content,
                Serializer.runtime_message_content(data.runtime_step, message.role)
              )
              |> Map.put(:runtime_step_sequence, data.runtime_step.sequence)

            true ->
              payload
          end

        payload =
          if selection,
            do:
              Map.put(
                payload,
                :working_open,
                working_payload(message, actor, data, selection, params["working_revision"])
              ),
            else: payload

        {:ok, payload}
    end
  end

  defp cursor_revisions(runtime, persisted_revision, base, costs_revision, params) do
    summary =
      case runtime_step(runtime) do
        step when is_map(step) -> Map.delete(step, :items)
        _ -> nil
      end

    view_revision =
      Serializer.poll_revision(
        {persisted_revision, base, costs_revision,
         if(summary, do: Map.take(summary, [:id, :sequence, :status, :response_final])),
         params["working_step_id"], params["working_sync"]}
      )

    revision =
      Serializer.poll_revision({view_revision, summary, Map.get(stream(runtime), :cursor)})

    {summary, view_revision, revision}
  end

  # Canonical reconciliation retires only the approximate stream. The controller
  # discards this hint whenever persisted content differs from the reader's copy.
  defp reconcile_cursor_runtime(
         {kind,
          %{step: %{id: id, sequence: sequence}, stream: %{cursor: %{"epoch" => epoch}}} =
            snapshot},
         nil
       )
       when kind in [:ok, :busy] do
    cursor = IntellectualClub.Generation.RuntimePoll.retired_cursor(epoch, id, sequence)
    {kind, %{snapshot | step: nil, stream: %{reset: false, cursor: cursor, targets: []}}}
  end

  defp reconcile_cursor_runtime(runtime, _step), do: runtime

  def persisted_revision(message) do
    Serializer.poll_revision(
      {message.id, trace_revision(message), message.status, message.role, message.updated_at}
    )
  end

  defp trace_revision(%{poll_revision: %{revision: revision}}), do: revision
  defp trace_revision(%{poll_revision: nil}), do: 0

  defp stream({kind, %{stream: stream}}) when kind in [:ok, :busy], do: stream
  defp stream(_runtime), do: %{}

  defp put_delta(payload, %{delta: %{text: text} = delta}) when text != "",
    do: Map.put(payload, :runtime_delta, delta)

  defp put_delta(payload, _stream), do: payload

  def response(message, actor, runtime, params, meta) do
    data = metadata(message, actor, runtime)
    costs = SubchatCosts.for_messages([message], actor, steps: data.steps)
    selection = selection(data, Map.get(params, "working_step_id"))
    # Finalization must replace runtime content IDs with canonical persisted IDs,
    # even when the last step was already committed before the message finalized.
    content_revision = Serializer.poll_revision({data.revision, message.status})
    runtime_revision = Serializer.poll_revision(data.runtime_step)
    base = Map.merge(meta, runtime_metadata(message, runtime))

    revision =
      Serializer.poll_revision(
        {base, data.revision, data.runtime_step, costs.revision, selection}
      )

    if params["revision"] == revision and params["content_revision"] == content_revision and
         (is_nil(data.runtime_step) or params["runtime_revision"] == runtime_revision) and
         (is_nil(selection) or params["working_revision"] == selection.revision) do
      :unchanged
    else
      persisted =
        if params["content_revision"] != content_revision,
          do: completed_payload(message, actor, data)

      retry_summary =
        PollCache.fetch(cache_key(message, actor, :retry_summary), data.revision, fn ->
          payload = persisted || completed_payload(message, actor, data)
          Map.take(payload.working, @retry_fields)
        end)

      summaries = data.summaries

      working =
        Serializer.working_summary(summaries)
        |> Map.merge(retry_summary)

      usage =
        Serializer.usage_summary(summaries,
          subchat_cost: Map.get(costs.costs_by_message_id, message.id)
        )

      payload =
        Map.merge(base, %{
          revision: revision,
          content_revision: content_revision,
          runtime_revision: runtime_revision,
          working: working,
          usage: usage
        })

      payload =
        if is_nil(persisted) do
          if data.runtime_step && params["runtime_revision"] != runtime_revision do
            payload
            |> Map.put(
              :runtime_content,
              Serializer.runtime_message_content(data.runtime_step, message.role)
            )
            |> Map.put(:runtime_step_sequence, data.runtime_step.sequence)
          else
            payload
          end
        else
          Map.put(
            payload,
            :content,
            Serializer.merge_runtime_message_content(
              persisted.content,
              data.runtime_step,
              message.role
            )
          )
        end

      payload =
        if selection do
          Map.put(
            payload,
            :working_open,
            working_payload(message, actor, data, selection, params["working_revision"])
          )
        else
          payload
        end

      {:ok, payload}
    end
  end

  def working(message, actor, requested_step_id, runtime) do
    data = metadata(message, actor, runtime)

    requested =
      if is_integer(requested_step_id), do: Integer.to_string(requested_step_id), else: "latest"

    selected = selection(data, requested)
    payload = working_payload(message, actor, data, selected, nil)
    if payload, do: {:ok, Map.put(payload, :message_id, message.id)}, else: {:error, :not_found}
  end

  defp runtime_metadata(message, runtime) do
    snapshot =
      case runtime do
        {kind, value} when kind in [:ok, :busy] -> value
        _other -> %{}
      end

    availability =
      case runtime do
        {:ok, _} -> "ready"
        {:busy, _} -> "busy"
        _other -> "absent"
      end

    status =
      if message.status == :generating,
        do: public_status(Map.get(snapshot, :status, message.status)),
        else: message.status

    phase =
      case Map.get(snapshot, :phase) do
        :provider -> :streaming
        :tools -> :waiting_tools
        nil -> if(status == :generating, do: :initializing, else: :finished)
        phase -> phase
      end

    slow? =
      availability == "busy" or
        phase in [
          :initializing,
          :recovering,
          :waiting_tools,
          :persisting,
          :backoff,
          :retry_backoff,
          :waiting_provider
        ]

    %{
      message_id: message.id,
      runtime: availability != "absent",
      availability: availability,
      phase: to_string(phase),
      poll_after_ms: if(slow?, do: 1750, else: 500),
      status: to_string(status),
      token_count: message.token_count,
      error_detail: message.error_detail,
      finished_at: Serializer.datetime_iso(message.finished_at)
    }
  end

  defp metadata(message, actor, runtime, compact? \\ false) do
    steps =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^message.id)
      |> Ash.Query.select(@step_fields)
      |> Ash.Query.sort(sequence: :asc, id: :asc)
      |> Ash.read!(actor: actor)

    step_ids = Enum.map(steps, & &1.id)
    items = if compact?, do: [], else: read_items(step_ids, actor)
    contents = if compact?, do: [], else: read_contents(Enum.map(items, & &1.id), actor)
    items_by_step = Enum.group_by(items, & &1.chat_message_step_id)
    contents_by_item = Enum.group_by(contents, & &1.chat_message_item_id)

    step_revisions =
      Map.new(steps, fn step ->
        rows =
          Enum.map(Map.get(items_by_step, step.id, []), fn item ->
            {Map.take(item, @item_fields),
             Enum.map(Map.get(contents_by_item, item.id, []), &Map.take(&1, @content_fields))}
          end)

        {step.id,
         Serializer.poll_revision(
           {Map.take(step, @step_fields), rows, if(compact?, do: trace_revision(message))}
         )}
      end)

    summaries = Enum.map(steps, &Serializer.working_step_summary/1)
    step = current_runtime_step(message, steps, runtime)

    summaries =
      if step do
        summaries
        |> Enum.reject(&(&1.id == step.id or &1.sequence == step.sequence))
        |> Kernel.++([Serializer.working_step_summary(step)])
        |> Enum.sort_by(& &1.sequence)
      else
        summaries
      end

    %{
      steps: steps,
      summaries: summaries,
      step_revisions: step_revisions,
      runtime_step: step,
      revision:
        Serializer.poll_revision({message.id, message.chat_id, message.role, step_revisions})
    }
  end

  defp read_items([], _actor), do: []

  defp read_items(ids, actor) do
    ids
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      ChatMessageItem
      |> Ash.Query.filter(chat_message_step_id in ^chunk)
      |> Ash.Query.select(@item_fields)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(actor: actor)
    end)
  end

  defp read_contents([], _actor), do: []

  defp read_contents(ids, actor) do
    ids
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      ChatMessageContent
      |> Ash.Query.filter(chat_message_item_id in ^chunk)
      |> Ash.Query.select(@content_fields)
      |> Ash.Query.sort(id: :asc)
      |> Ash.read!(actor: actor)
    end)
  end

  defp completed_payload(message, actor, data) do
    PollCache.fetch(cache_key(message, actor, :display), data.revision, fn ->
      ChatBranchPayload.message(message, actor, subchat_costs_by_message_id: %{})
      |> Map.take([:content, :working])
    end)
  end

  defp selection(_data, nil), do: nil

  defp selection(data, requested) do
    id =
      case requested do
        value when value in ["latest", ""] ->
          case List.last(data.summaries) do
            nil -> nil
            summary -> summary.id
          end

        value when is_binary(value) ->
          case Integer.parse(value) do
            {id, ""} when id > 0 -> id
            _other -> :invalid
          end

        value when is_integer(value) and value > 0 ->
          value

        _other ->
          :invalid
      end

    revision =
      if data.runtime_step && data.runtime_step.id == id,
        do: Serializer.poll_revision(data.runtime_step),
        else: Map.get(data.step_revisions, id)

    %{id: id, revision: Serializer.poll_revision({id, revision})}
  end

  defp working_payload(message, actor, data, selection, client_revision) do
    if selection.id && not Enum.any?(data.summaries, &(&1.id == selection.id)) do
      nil
    else
      payload = %{
        step_count: length(data.summaries),
        steps: data.summaries,
        selected_step_id: selection.id,
        revision: selection.revision
      }

      if client_revision == selection.revision do
        payload
      else
        Map.put(payload, :step, step_detail(message, actor, data, selection))
      end
    end
  end

  defp step_detail(_message, _actor, _data, %{id: nil}), do: nil

  defp step_detail(message, actor, data, selection) do
    if data.runtime_step && data.runtime_step.id == selection.id do
      data.runtime_step
    else
      PollCache.fetch(cache_key(message, actor, {:step, selection.id}), selection.revision, fn ->
        ChatMessageStep
        |> Ash.Query.filter(chat_message_id == ^message.id and id == ^selection.id)
        |> Ash.Query.select(@step_fields)
        |> Ash.Query.load(
          [
            items: [
              :id,
              :sequence,
              :created_at,
              :type,
              :tool_call_item_id,
              contents: [
                :id,
                :external_id,
                :sequence,
                :kind,
                :content_text,
                :content_json,
                :file_id,
                file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]
              ]
            ]
          ],
          strict?: true
        )
        |> Ash.read_one!(actor: actor)
        |> case do
          nil -> nil
          step -> Serializer.step(step)
        end
      end)
    end
  end

  defp cache_key(message, actor, kind),
    do: {Serializer.poll_revision(actor), message.id, message.chat_id, kind}

  # A committed provider response or successor owns its canonical items. The
  # worker may still expose the predecessor until its async write is acknowledged.
  # Never let that stale snapshot replace durable IDs, artifacts or step details.
  defp current_runtime_step(%{status: :generating}, steps, runtime) do
    case {List.last(steps), runtime_step(runtime)} do
      {%{id: id, sequence: sequence, status: :waiting_provider, response_final: false},
       %{id: id, sequence: sequence} = step} ->
        step

      _other ->
        nil
    end
  end

  defp current_runtime_step(_message, _steps, _runtime), do: nil

  defp public_status(:initializing), do: :generating
  defp public_status(status), do: status

  defp runtime_step({kind, %{step: step}}) when kind in [:ok, :busy], do: step
  defp runtime_step(_runtime), do: nil
end
