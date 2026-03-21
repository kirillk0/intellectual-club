defmodule IntellectualClub.Generation.Persistence do
  @moduledoc """
  Persists generation outcomes in a single database update.

  This module uses Ecto directly and must not depend on Ash resources.
  """

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Db
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.TokenCounter

  def ensure_step_started!(message_id, raw_request, opts \\ [])
      when is_integer(message_id) and is_list(opts) do
    ensure_step_started!(message_id, 1, raw_request, opts)
  end

  def ensure_step_started!(message_id, sequence, raw_request, opts)
      when is_integer(message_id) and is_integer(sequence) and is_list(opts) do
    repo = Db.repo()
    now = DateTime.utc_now()
    started_at = Keyword.get(opts, :started_at, now)

    {:ok, step_id} =
      repo.transaction(fn ->
        owner_id = load_message_owner_id!(repo, message_id)

        step_row = %{
          chat_message_id: message_id,
          owner_id: owner_id,
          sequence: sequence,
          status: "waiting_provider",
          raw_request: dump_json(raw_request || %{}),
          raw_response: dump_json(nil),
          response_final: dump_boolean(false),
          input_tokens: nil,
          output_tokens: nil,
          cached_input_tokens: nil,
          reasoning_tokens: nil,
          cost: nil,
          finished_at: nil,
          created_at: started_at,
          updated_at: now
        }

        _ =
          repo.insert_all("chat_message_steps", [step_row],
            on_conflict: {:replace, [:raw_request, :updated_at, :status, :finished_at]},
            conflict_target: [:chat_message_id, :sequence]
          )

        repo.one!(
          from(s in "chat_message_steps",
            where: s.chat_message_id == ^message_id and s.sequence == ^sequence,
            select: s.id
          )
        )
      end)

    step_id
  end

  def persist_step_trace_only!(message_id, %RuntimeTrace.Step{} = runtime_step)
      when is_integer(message_id) do
    now = DateTime.utc_now()
    repo = Db.repo()

    repo.transaction(fn ->
      owner_id = load_message_owner_id!(repo, message_id)

      persist_step_trace!(
        repo,
        %{
          message_id: message_id,
          owner_id: owner_id,
          runtime_step: runtime_step,
          step_status: "done",
          now: now
        }
      )
    end)

    :ok
  end

  def persist_step_waiting_tools!(message_id, %RuntimeTrace.Step{} = runtime_step)
      when is_integer(message_id) do
    now = DateTime.utc_now()
    repo = Db.repo()

    repo.transaction(fn ->
      owner_id = load_message_owner_id!(repo, message_id)

      persist_step_trace!(
        repo,
        %{
          message_id: message_id,
          owner_id: owner_id,
          runtime_step: runtime_step,
          step_status: "waiting_tools",
          now: now
        }
      )
    end)

    :ok
  end

  def list_generating_messages_for_resume! do
    repo = Db.repo()

    repo.all(
      from(m in "chat_messages",
        where: m.status == "generating",
        select: %{id: m.id, owner_id: m.owner_id}
      )
    )
  end

  def cancel_orphaned_generating_messages!(chat_id) when is_integer(chat_id) do
    now = DateTime.utc_now()
    repo = Db.repo()

    ids =
      repo.all(
        from(m in "chat_messages",
          where: m.chat_id == ^chat_id and m.status == "generating",
          select: m.id
        )
      )

    if ids != [] do
      from(s in "chat_message_steps",
        where: s.chat_message_id in ^ids and s.status in ["waiting_provider", "waiting_tools"]
      )
      |> repo.update_all(set: [status: "canceled", finished_at: now, updated_at: now])
    end

    from(m in "chat_messages", where: m.chat_id == ^chat_id and m.status == "generating")
    |> repo.update_all(
      set: [
        status: "canceled",
        error_detail: "Orphaned generation (worker not found)",
        finished_at: now,
        updated_at: now
      ]
    )

    :ok
  end

  def cancel_orphaned_generating_message!(message_id) when is_integer(message_id) do
    now = DateTime.utc_now()
    repo = Db.repo()

    from(s in "chat_message_steps",
      where:
        s.chat_message_id == ^message_id and s.status in ["waiting_provider", "waiting_tools"]
    )
    |> repo.update_all(set: [status: "canceled", finished_at: now, updated_at: now])

    from(m in "chat_messages", where: m.id == ^message_id and m.status == "generating")
    |> repo.update_all(
      set: [
        status: "canceled",
        error_detail: "Orphaned generation (worker not found)",
        finished_at: now,
        updated_at: now
      ]
    )

    :ok
  end

  def persist_completed!(message_id, %RuntimeTrace.Step{} = runtime_step) do
    now = DateTime.utc_now()
    repo = Db.repo()

    repo.transaction(fn ->
      owner_id = load_message_owner_id!(repo, message_id)
      answer_text = RuntimeTrace.text_for_item_type(runtime_step, :answer)

      from(m in "chat_messages", where: m.id == ^message_id)
      |> repo.update_all(
        set: [
          status: "done",
          error_detail: nil,
          token_count: TokenCounter.estimate(answer_text),
          finished_at: now,
          updated_at: now
        ]
      )

      persist_step_trace!(
        repo,
        %{
          message_id: message_id,
          owner_id: owner_id,
          runtime_step: runtime_step,
          step_status: "done",
          now: now
        }
      )
    end)

    :ok
  end

  def persist_canceled!(message_id, %RuntimeTrace.Step{} = runtime_step) do
    now = DateTime.utc_now()
    repo = Db.repo()

    repo.transaction(fn ->
      owner_id = load_message_owner_id!(repo, message_id)
      answer_text = RuntimeTrace.text_for_item_type(runtime_step, :answer)

      from(m in "chat_messages", where: m.id == ^message_id)
      |> repo.update_all(
        set: [
          status: "canceled",
          token_count: TokenCounter.estimate(answer_text),
          finished_at: now,
          updated_at: now
        ]
      )

      persist_step_trace!(
        repo,
        %{
          message_id: message_id,
          owner_id: owner_id,
          runtime_step: runtime_step,
          step_status: "canceled",
          now: now
        }
      )
    end)

    :ok
  end

  def persist_error!(message_id, %RuntimeTrace.Step{} = runtime_step, error_text) do
    now = DateTime.utc_now()
    repo = Db.repo()

    repo.transaction(fn ->
      owner_id = load_message_owner_id!(repo, message_id)
      answer_text = RuntimeTrace.text_for_item_type(runtime_step, :answer)

      from(m in "chat_messages", where: m.id == ^message_id)
      |> repo.update_all(
        set: [
          status: "error",
          error_detail: error_text,
          token_count: TokenCounter.estimate(answer_text),
          finished_at: now,
          updated_at: now
        ]
      )

      persist_step_trace!(
        repo,
        %{
          message_id: message_id,
          owner_id: owner_id,
          runtime_step: runtime_step,
          step_status: "error",
          now: now
        }
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
    now = DateTime.utc_now()
    repo = Db.repo()

    repo.transaction(fn ->
      step_ids =
        repo.all(
          from(s in "chat_message_steps",
            where: s.chat_message_id == ^message_id and s.sequence >= ^from_sequence,
            select: s.id
          )
        )

      if step_ids == [] do
        raise ArgumentError, "Retry step not found"
      end

      item_ids =
        repo.all(
          from(i in "chat_message_items",
            where: i.chat_message_step_id in ^step_ids,
            select: i.id
          )
        )

      if item_ids != [] do
        from(c in "chat_message_contents", where: c.chat_message_item_id in ^item_ids)
        |> repo.delete_all()
      end

      from(i in "chat_message_items", where: i.chat_message_step_id in ^step_ids)
      |> repo.delete_all()

      from(s in "chat_message_steps", where: s.id in ^step_ids)
      |> repo.delete_all()

      from(m in "chat_messages", where: m.id == ^message_id)
      |> repo.update_all(
        set: [
          status: "generating",
          error_detail: nil,
          token_count: 0,
          finished_at: nil,
          updated_at: now
        ]
      )
    end)

    :ok
  end

  defp load_message_owner_id!(repo, message_id) do
    repo.one!(
      from(m in "chat_messages",
        where: m.id == ^message_id,
        select: m.owner_id
      )
    )
  end

  defp persist_step_trace!(
         repo,
         %{
           message_id: message_id,
           owner_id: owner_id,
           runtime_step: runtime_step,
           step_status: step_status,
           now: now
         }
       ) do
    persistable = RuntimeTrace.persistable(runtime_step)

    sequence =
      case Map.get(persistable, :sequence) do
        value when is_integer(value) and value > 0 -> value
        _ -> 1
      end

    created_at =
      case Map.get(persistable, :started_at) do
        %DateTime{} = dt -> dt
        _ -> now
      end

    response_final = Map.get(persistable, :response_final, false)
    finished_at = if(step_status in ["done", "canceled", "error"], do: now, else: nil)

    raw_request = dump_json(Map.get(persistable, :raw_request) || %{})
    raw_response = dump_json(Map.get(persistable, :raw_response))

    step_row = %{
      chat_message_id: message_id,
      owner_id: owner_id,
      sequence: sequence,
      status: step_status,
      raw_request: raw_request,
      raw_response: raw_response,
      response_final: dump_boolean(response_final),
      input_tokens: Map.get(persistable, :input_tokens),
      output_tokens: Map.get(persistable, :output_tokens),
      cached_input_tokens: Map.get(persistable, :cached_input_tokens),
      reasoning_tokens: Map.get(persistable, :reasoning_tokens),
      cost: Map.get(persistable, :cost),
      finished_at: finished_at,
      created_at: created_at,
      updated_at: now
    }

    _ =
      repo.insert_all("chat_message_steps", [step_row],
        on_conflict:
          {:replace,
           [
             :status,
             :raw_request,
             :raw_response,
             :response_final,
             :input_tokens,
             :output_tokens,
             :cached_input_tokens,
             :reasoning_tokens,
             :cost,
             :finished_at,
             :updated_at
           ]},
        conflict_target: [:chat_message_id, :sequence]
      )

    step_id =
      repo.one!(
        from(s in "chat_message_steps",
          where: s.chat_message_id == ^message_id and s.sequence == ^sequence,
          select: s.id
        )
      )

    {items, contents} = build_step_items_and_contents(step_id, owner_id, persistable, now: now)

    _ =
      repo.insert_all("chat_message_items", items,
        on_conflict: :nothing,
        conflict_target: [:chat_message_step_id, :sequence]
      )

    item_ids =
      repo.all(
        from(i in "chat_message_items",
          where: i.chat_message_step_id == ^step_id,
          select: {i.sequence, i.id}
        )
      )
      |> Map.new()

    contents =
      Enum.map(contents, fn content_row ->
        seq = content_row[:_item_sequence]
        item_id = Map.fetch!(item_ids, seq)

        content_row
        |> Map.delete(:_item_sequence)
        |> Map.put(:chat_message_item_id, item_id)
      end)

    _ =
      repo.insert_all("chat_message_contents", contents,
        on_conflict: :nothing,
        conflict_target: [:chat_message_item_id, :sequence]
      )

    :ok
  end

  defp build_step_items_and_contents(step_id, owner_id, persistable, opts)
       when is_integer(step_id) and is_integer(owner_id) and is_map(persistable) and
              is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    items = Map.get(persistable, :items, [])

    items =
      if is_list(items) do
        items
      else
        []
      end

    items =
      items
      |> Enum.filter(&is_map/1)
      |> Enum.sort_by(fn item -> Map.get(item, :sequence, 0) end)

    item_rows =
      Enum.map(items, fn item ->
        created_at =
          case Map.get(item, :created_at) do
            %DateTime{} = dt -> dt
            _ -> now
          end

        %{
          chat_message_step_id: step_id,
          owner_id: owner_id,
          sequence: Map.get(item, :sequence, 1),
          type: Map.get(item, :type, "other") |> to_string(),
          created_at: created_at,
          updated_at: now
        }
      end)

    content_rows =
      items
      |> Enum.flat_map(fn item ->
        item_sequence = Map.get(item, :sequence, 1)
        contents = Map.get(item, :contents, [])
        contents = if is_list(contents), do: contents, else: []

        contents =
          contents
          |> Enum.filter(&is_map/1)
          |> Enum.sort_by(fn content -> Map.get(content, :sequence, 0) end)

        Enum.map(contents, fn content ->
          %{
            _item_sequence: item_sequence,
            owner_id: owner_id,
            external_id: Map.get(content, :external_id) |> dump_uuid(),
            sequence: Map.get(content, :sequence, 1),
            kind: Map.get(content, :kind, "text") |> to_string(),
            file_id: Map.get(content, :file_id),
            content_text: Map.get(content, :content_text, "") |> to_string(),
            content_json: dump_json(Map.get(content, :content_json)),
            created_at: now,
            updated_at: now
          }
        end)
      end)

    {item_rows, content_rows}
  end

  defp dump_json(nil), do: nil

  defp dump_json(value) when is_map(value) or is_list(value) do
    case Db.adapter() do
      :sqlite -> Jason.encode!(value)
      :postgres -> value
    end
  end

  defp dump_json(value) do
    case Db.adapter() do
      :sqlite -> Jason.encode!(%{"raw" => value})
      :postgres -> %{"raw" => value}
    end
  end

  defp dump_uuid(nil), do: dump_uuid(Ash.UUID.generate())

  defp dump_uuid(value) do
    case Db.adapter() do
      :sqlite -> to_string(value)
      :postgres -> value |> to_string() |> Ecto.UUID.dump!()
    end
  end

  defp dump_boolean(value) when is_boolean(value) do
    case Db.adapter() do
      :sqlite -> if(value, do: 1, else: 0)
      :postgres -> value
    end
  end
end
