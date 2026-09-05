defmodule IntellectualClub.Generation.ToolResult do
  @moduledoc """
  Canonical persisted tool result linked to a tool call item.
  """

  alias IntellectualClub.Tools.ExecutionResult

  @type t :: %__MODULE__{
          item_id: integer() | nil,
          step_id: integer() | nil,
          tool_call_item_id: integer() | nil,
          sequence: integer() | nil,
          call_id: String.t(),
          name: String.t(),
          args: map(),
          text: String.t(),
          raw: map(),
          result_raw: map(),
          responses_item: map() | nil,
          media_contents: list(map()),
          artifact_contents: list(map())
        }

  defstruct item_id: nil,
            step_id: nil,
            tool_call_item_id: nil,
            sequence: nil,
            call_id: "",
            name: "",
            args: %{},
            text: "",
            raw: %{},
            result_raw: %{},
            responses_item: nil,
            media_contents: [],
            artifact_contents: []

  @doc "Converts a driver result into the payload used by tool-result persistence."
  @spec execution_payload(ExecutionResult.t()) :: map()
  def execution_payload(%ExecutionResult{} = result) do
    result = ExecutionResult.normalize(result)

    %{
      text: result.text,
      result_raw: result.raw,
      media_contents: attachment_contents(result.media, 2),
      artifact_contents: attachment_contents(result.artifacts, 1)
    }
  end

  defp attachment_contents(attachments, first_sequence) do
    attachments
    |> Enum.with_index(first_sequence)
    |> Enum.flat_map(fn {attachment, sequence} ->
      case media_content(attachment, sequence) do
        nil -> []
        content -> [content]
      end
    end)
  end

  defp media_content(media, sequence) do
    file_id = Map.get(media, :file_id)
    filename = Map.get(media, :filename)
    mime_type = Map.get(media, :mime_type)
    sha256 = Map.get(media, :sha256)

    if is_integer(file_id) and is_binary(filename) and is_binary(mime_type) and is_binary(sha256) do
      %{
        external_id: Ash.UUID.generate(),
        sequence: sequence,
        kind: :media,
        file_id: file_id,
        file: %{
          id: file_id,
          external_id: Map.get(media, :file_external_id),
          filename: filename,
          mime_type: mime_type,
          size_bytes: Map.get(media, :size_bytes) || 0,
          sha256: sha256
        }
      }
    end
  end
end
