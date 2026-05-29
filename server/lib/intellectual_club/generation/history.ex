defmodule IntellectualClub.Generation.History do
  @moduledoc """
  Provider-independent helpers for reading persisted model history.

  History is reconstructed from persisted trace messages and legacy
  `%{role, content}` entries. Provider adapters are responsible for projecting
  this canonical structure into provider-specific request payloads.
  """

  alias IntellectualClub.Chat.Media

  @allowed_roles ["user", "assistant"]

  @doc """
  Normalizes legacy `%{role, content}` history messages.
  """
  def normalize_message(%{role: role, content: content}) do
    normalize_role_content(role, content)
  end

  def normalize_message(%{"role" => role, "content" => content}) do
    normalize_role_content(role, content)
  end

  def normalize_message(_other), do: nil

  @doc """
  Returns the normalized role for a trace or legacy history message.
  """
  def message_role(message) when is_map(message) do
    message
    |> Map.get(:role, Map.get(message, "role"))
    |> normalize_role()
  end

  def message_role(_other), do: nil

  @doc """
  Returns true when a history entry is a persisted trace message.
  """
  def trace_message?(message) when is_map(message) do
    steps = Map.get(message, :steps, Map.get(message, "steps"))
    is_list(steps)
  end

  def trace_message?(_other), do: false

  @doc """
  Returns trace steps from a persisted history message.
  """
  def steps(message) when is_map(message) do
    Map.get(message, :steps, Map.get(message, "steps")) || []
  end

  def steps(_other), do: []

  @doc """
  Returns trace items from a persisted step.
  """
  def items(step) when is_map(step) do
    Map.get(step, :items, Map.get(step, "items")) || []
  end

  def items(_other), do: []

  @doc """
  Returns a persisted trace item id.
  """
  def item_id(item) when is_map(item) do
    Map.get(item, :id, Map.get(item, "id"))
  end

  def item_id(_other), do: nil

  @doc """
  Returns the canonical persisted tool result -> tool call link.
  """
  def tool_call_item_id(item) when is_map(item) do
    Map.get(item, :tool_call_item_id, Map.get(item, "tool_call_item_id"))
  end

  def tool_call_item_id(_other), do: nil

  @doc """
  Returns trace contents from a persisted item.
  """
  def contents(item) when is_map(item) do
    Map.get(item, :contents, Map.get(item, "contents")) || []
  end

  def contents(_other), do: []

  @doc """
  Normalizes a trace item type.
  """
  def item_type(%{} = item) do
    item
    |> Map.get(:type, Map.get(item, "type"))
    |> item_type()
  end

  def item_type(value) when is_binary(value) do
    case value do
      "input" -> :input
      "answer" -> :answer
      "reasoning" -> :reasoning
      "tool_call" -> :tool_call
      "tool_result" -> :tool_result
      "artifact" -> :artifact
      _other -> :other
    end
  end

  def item_type(value) when is_atom(value), do: value |> Atom.to_string() |> item_type()
  def item_type(_other), do: :other

  @doc """
  Normalizes a trace content kind.
  """
  def content_kind(%{} = content) do
    content
    |> Map.get(:kind, Map.get(content, "kind"))
    |> content_kind()
  end

  def content_kind(value) when is_binary(value) do
    case value do
      "text" -> :text
      "opaque" -> :opaque
      "media" -> :media
      _other -> :other
    end
  end

  def content_kind(value) when is_atom(value), do: value |> Atom.to_string() |> content_kind()
  def content_kind(_other), do: :other

  @doc """
  Extracts ordered text from a persisted trace item.
  """
  def item_text(item) do
    item
    |> contents()
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn content ->
      text = Map.get(content, :content_text, Map.get(content, "content_text"))

      if content_kind(content) == :text and is_binary(text) do
        [text]
      else
        []
      end
    end)
    |> Enum.join("")
  end

  @doc """
  Extracts ordered text for all items of a given type from a persisted message.
  """
  def project_text_for_item_type(message, wanted_type) do
    message
    |> ordered_items()
    |> Enum.filter(&(item_type(&1) == wanted_type))
    |> Enum.map(&item_text/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Extracts ordered contents for all items of a given type from a persisted message.
  """
  def project_contents_for_item_type(message, wanted_type) do
    message
    |> ordered_items()
    |> Enum.filter(&(item_type(&1) == wanted_type))
    |> Enum.flat_map(&contents/1)
    |> Enum.sort_by(&sort_seq/1)
  end

  @doc """
  Extracts ordered opaque JSON payloads from a persisted item.
  """
  def opaque_payloads(item) do
    item
    |> contents()
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn content ->
      content_json = Map.get(content, :content_json, Map.get(content, "content_json"))

      if content_kind(content) == :opaque and is_map(content_json) do
        [Map.new(content_json)]
      else
        []
      end
    end)
  end

  @doc """
  Extracts ordered media contents from a persisted item.
  """
  def media_contents_for_item(item) do
    item
    |> contents()
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.filter(&Media.media_content?/1)
  end

  @doc """
  Returns a stable sequence value for persisted trace maps.
  """
  def sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  def sort_seq(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  def sort_seq(_other), do: 0

  @doc """
  Normalizes user/assistant roles.
  """
  def normalize_role(role) when is_atom(role), do: role |> Atom.to_string() |> normalize_role()
  def normalize_role("user"), do: "user"
  def normalize_role("assistant"), do: "assistant"
  def normalize_role(_other), do: nil

  @doc """
  Normalizes legacy history content without changing provider wire shapes.
  """
  def normalize_content(nil), do: ""
  def normalize_content(content) when is_binary(content), do: content
  def normalize_content(content) when is_list(content), do: Enum.map(content, &Map.new/1)
  def normalize_content(content) when is_map(content), do: Map.new(content)
  def normalize_content(content), do: to_string(content)

  defp normalize_role_content(role, content) do
    role = normalize_role(role)

    if role in @allowed_roles do
      %{"role" => role, "content" => normalize_content(content)}
    else
      nil
    end
  end

  defp ordered_items(message) do
    message
    |> steps()
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn step ->
      step
      |> items()
      |> Enum.sort_by(&sort_seq/1)
    end)
  end
end
