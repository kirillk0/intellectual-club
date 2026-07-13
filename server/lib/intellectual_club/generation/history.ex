defmodule IntellectualClub.Generation.History do
  @moduledoc """
  Provider-independent helpers for reading persisted model history.

  History is reconstructed from persisted trace messages and legacy
  `%{role, content}` entries. Provider adapters are responsible for projecting
  this canonical structure into provider-specific request payloads.
  """

  alias IntellectualClub.Chat.Media

  @allowed_roles ["user", "assistant"]
  @user_input_item_types [:input, :handoff_request, :handoff_context]
  @assistant_answer_item_types [:answer, :handoff_summary]
  @item_types [
    :input,
    :handoff_request,
    :handoff_context,
    :steering,
    :answer,
    :handoff_summary,
    :reasoning,
    :tool_call,
    :tool_result,
    :artifact,
    :error,
    :other
  ]
  @content_kinds [:text, :opaque, :media]

  @doc """
  Returns item types that project as user input in provider histories.
  """
  def user_input_item_types, do: @user_input_item_types

  @doc """
  Returns item types that project as assistant answers in provider histories.
  """
  def assistant_answer_item_types, do: @assistant_answer_item_types

  @doc """
  Returns true when an item or item type projects as user input.
  """
  def user_input_item?(item_or_type), do: item_type(item_or_type) in @user_input_item_types

  @doc """
  Returns true when an item or item type projects as an assistant answer.
  """
  def assistant_answer_item?(item_or_type),
    do: item_type(item_or_type) in @assistant_answer_item_types

  @doc """
  Normalizes legacy `%{role, content}` history messages.
  """
  def normalize_message(%{role: role, content: content}) do
    normalize_role_content(role_to_wire(role), content)
  end

  def normalize_message(%{"role" => role, "content" => content}) do
    normalize_role_content(legacy_role(role), content)
  end

  def normalize_message(_other), do: nil

  @doc """
  Returns the provider wire role for a canonical trace message.
  """
  def message_role(%{role: role}), do: role_to_wire(role)

  def message_role(_other), do: nil

  @doc """
  Returns true when a history entry is a persisted trace message.
  """
  def trace_message?(%{steps: steps}), do: is_list(steps)

  def trace_message?(_other), do: false

  @doc """
  Returns trace steps from a persisted history message.
  """
  def steps(%{steps: steps}) when is_list(steps), do: steps

  def steps(_other), do: []

  @doc """
  Returns trace items from a persisted step.
  """
  def items(%{items: items}) when is_list(items), do: items

  def items(_other), do: []

  @doc """
  Returns a persisted trace item id.
  """
  def item_id(%{id: id}), do: id

  def item_id(_other), do: nil

  @doc """
  Returns the canonical persisted tool result -> tool call link.
  """
  def tool_call_item_id(%{tool_call_item_id: tool_call_item_id}), do: tool_call_item_id

  def tool_call_item_id(_other), do: nil

  @doc """
  Returns trace contents from a persisted item.
  """
  def contents(%{contents: contents}) when is_list(contents), do: contents

  def contents(_other), do: []

  @doc """
  Returns the canonical trace item type.
  """
  def item_type(%{type: type}), do: item_type(type)
  def item_type(value) when value in @item_types, do: value
  def item_type(_other), do: :other

  @doc """
  Returns the canonical trace content kind.
  """
  def content_kind(%{kind: kind}), do: content_kind(kind)
  def content_kind(value) when value in @content_kinds, do: value
  def content_kind(_other), do: :other

  @doc """
  Extracts ordered text from a persisted trace item.
  """
  def item_text(item) do
    item
    |> contents()
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn content ->
      text = Map.get(content, :content_text)

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
    project_text_for_item_types(message, [wanted_type])
  end

  @doc """
  Extracts ordered text for all items matching any of the given types.
  """
  def project_text_for_item_types(message, wanted_types) when is_list(wanted_types) do
    message
    |> ordered_items()
    |> Enum.filter(&(item_type(&1) in wanted_types))
    |> Enum.map(&item_text/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Extracts ordered contents for all items of a given type from a persisted message.
  """
  def project_contents_for_item_type(message, wanted_type) do
    project_contents_for_item_types(message, [wanted_type])
  end

  @doc """
  Extracts ordered contents for all items matching any of the given types.
  """
  def project_contents_for_item_types(message, wanted_types) when is_list(wanted_types) do
    message
    |> ordered_items()
    |> Enum.filter(&(item_type(&1) in wanted_types))
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
      content_json = Map.get(content, :content_json)

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
  def sort_seq(_other), do: 0

  @doc """
  Normalizes legacy history content without changing provider wire shapes.
  """
  def normalize_content(nil), do: ""
  def normalize_content(content) when is_binary(content), do: content
  def normalize_content(content) when is_list(content), do: Enum.map(content, &Map.new/1)
  def normalize_content(content) when is_map(content), do: Map.new(content)
  def normalize_content(content), do: to_string(content)

  defp normalize_role_content(role, content) do
    if role in @allowed_roles do
      %{"role" => role, "content" => normalize_content(content)}
    else
      nil
    end
  end

  defp role_to_wire(:user), do: "user"
  defp role_to_wire(:assistant), do: "assistant"
  defp role_to_wire(_other), do: nil

  defp legacy_role("user"), do: "user"
  defp legacy_role("assistant"), do: "assistant"
  defp legacy_role(_other), do: nil

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
