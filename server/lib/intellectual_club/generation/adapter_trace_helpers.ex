defmodule IntellectualClub.Generation.AdapterTraceHelpers do
  @moduledoc false

  alias IntellectualClub.Generation.RuntimeTrace

  def apply_media_contents_to_trace(runtime_step, _item_key, _item_type, []), do: runtime_step

  def apply_media_contents_to_trace(runtime_step, item_key, item_type, media_contents)
      when is_list(media_contents) do
    Enum.reduce(media_contents, runtime_step, fn content, step ->
      RuntimeTrace.apply_event(
        step,
        {:set_media, item_key, item_type, Map.get(content, :sequence, 1), content}
      )
    end)
  end

  def apply_artifacts_to_trace(runtime_step, %{artifact_contents: []}), do: runtime_step

  def apply_artifacts_to_trace(runtime_step, %{
        call_id: call_id,
        artifact_contents: artifact_contents
      }) do
    Enum.reduce(Enum.with_index(artifact_contents, 1), runtime_step, fn {content, idx}, step ->
      key = "artifact:" <> to_string(call_id) <> ":" <> Integer.to_string(idx)

      step
      |> RuntimeTrace.apply_event({:ensure_item, key, :artifact, nil})
      |> RuntimeTrace.apply_event({:set_media, key, :artifact, 1, Map.put(content, :sequence, 1)})
    end)
  end
end
