defmodule IntellectualClub.Generation.RuntimePoll do
  @moduledoc """
  Demand-driven UI projection with a constant-size, client-owned cursor.

  Only the selected text block is streamed. Other existing blocks may be stale
  until a structural reset or a persisted step boundary. No event log, subscriber
  state or serialized snapshot is retained by the Worker.
  """
  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClubWeb.Bff.Serializer

  @stream_types [:answer, :handoff_summary, :reasoning]

  def poll(nil, epoch, _cursor) do
    %{step: nil, stream: %{reset: false, cursor: %{"epoch" => epoch}, targets: []}}
  end

  def poll(%{id: id, sequence: sequence}, epoch, %{
        "epoch" => epoch,
        "step" => id,
        "sequence" => sequence,
        "retired" => true
      }) do
    # Retirement deliberately ignores all trace mutations, including structure.
    %{step: nil, stream: %{reset: false, cursor: retired_cursor(epoch, id, sequence)}}
  end

  def poll(step, epoch, cursor) do
    summary = RuntimeTrace.snapshot(%{step | items_by_key: %{}})

    base = %{
      "epoch" => epoch,
      "step" => step.id,
      "sequence" => step.sequence,
      "structure" => step.structure_revision
    }

    case selected(step, cursor, base) do
      {:ok, item, content, offset} ->
        text = content.content_text || ""
        next = Map.put(cursor, "offset", byte_size(text))

        delta = %{
          step_id: step.id,
          step_sequence: step.sequence,
          item_id: -100 - item.sequence,
          item_sequence: item.sequence,
          item_type: Atom.to_string(item.type),
          content_id: -20_000 - item.sequence * 1_000 - content.sequence,
          sequence: content.sequence,
          from: offset,
          to: byte_size(text),
          text: binary_part(text, offset, byte_size(text) - offset)
        }

        %{step: summary, stream: %{reset: false, cursor: next, delta: delta}}

      :empty ->
        %{step: summary, stream: %{reset: false, cursor: base}}

      :reset ->
        snapshot =
          step |> RuntimeTrace.snapshot() |> Serializer.normalize_runtime_step_for_client()

        targets = targets(step, base)

        preferred =
          Enum.find(targets, &(&1.item_type in ["answer", "handoff_summary"])) ||
            Enum.find(targets, &(&1.item_type == "reasoning")) || List.first(targets)

        next = if preferred, do: preferred.cursor, else: base
        %{step: snapshot, stream: %{reset: true, cursor: next, targets: targets}}
    end
  end

  @doc "A client-owned hint to ignore this runtime step, never persisted content."
  def retired_cursor(epoch, id, sequence),
    do: %{"epoch" => epoch, "step" => id, "sequence" => sequence, "retired" => true}

  defp selected(step, cursor, base) when is_map(cursor) do
    if Map.take(cursor, Map.keys(base)) == base do
      case {cursor["item"], cursor["content"]} do
        {nil, nil} ->
          :empty

        {key, sequence} when is_binary(key) and is_integer(sequence) ->
          with %{contents_by_sequence: contents} = item <- Map.get(step.items_by_key, key),
               true <- item.type in @stream_types,
               %{kind: :text} = content <- Map.get(contents, sequence),
               true <- content.external_id == cursor["id"],
               true <- content.text_generation == cursor["generation"],
               offset when is_integer(offset) and offset >= 0 <- cursor["offset"],
               text = content.content_text || "",
               true <- offset <= byte_size(text),
               true <- boundary?(text, offset) do
            {:ok, item, content, offset}
          else
            _ -> :reset
          end

        _ ->
          :reset
      end
    else
      :reset
    end
  end

  defp selected(_step, _cursor, _base), do: :reset

  # A UTF-8 offset must not point at a continuation byte. Never scan the prefix.
  defp boundary?(text, offset) when byte_size(text) == offset, do: true

  defp boundary?(text, offset),
    do: :binary.at(text, offset) < 128 or :binary.at(text, offset) >= 192

  defp targets(step, base) do
    step.items_by_key
    |> Map.values()
    |> Enum.filter(&(&1.type in @stream_types))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(fn item ->
      item.contents_by_sequence
      |> Map.values()
      |> Enum.filter(&(&1.kind == :text))
      |> Enum.sort_by(& &1.sequence)
      |> Enum.map(fn content ->
        %{
          item_type: Atom.to_string(item.type),
          cursor:
            Map.merge(base, %{
              "item" => item.key,
              "content" => content.sequence,
              "id" => content.external_id,
              "generation" => content.text_generation,
              "offset" => byte_size(content.content_text || "")
            })
        }
      end)
    end)
  end
end
