defmodule IntellectualClub.Generation.History do
  @moduledoc """
  Provider-independent helpers for reading persisted model history.

  History is reconstructed from persisted trace messages and legacy
  `%{role, content}` entries. Provider adapters are responsible for projecting
  this canonical structure into provider-specific request payloads.
  """

  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Chat.HandoffRolloff

  @allowed_roles ["user", "assistant"]
  @missing_user_message_placeholder "<There is no user message yet, you should write first>"
  @user_input_item_types [
    :input,
    :handoff_request,
    :handoff_context,
    :handoff_history,
    :handoff_message
  ]
  @assistant_answer_item_types [:answer, :handoff_summary]
  @item_types [
    :input,
    :handoff_request,
    :handoff_context,
    :handoff_history,
    :handoff_message,
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
  Ensures canonical history has non-empty user messages at both boundaries.

  Existing messages and their steps remain separate. Empty user messages are
  replaced with a provider-independent placeholder message.
  """
  @spec fix_role_alteration([term()]) :: [term()]
  def fix_role_alteration(history) when is_list(history) do
    history
    |> Enum.map(&replace_empty_user_message/1)
    |> ensure_user_boundaries()
  end

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
    |> Enum.flat_map(fn item -> item |> contents() |> Enum.sort_by(&sort_seq/1) end)
  end

  @doc """
  Projects user input contents, rebuilding structured handoff context for model input.
  """
  def project_user_input_contents(message) do
    items =
      message
      |> ordered_items()
      |> Enum.filter(&user_input_item?/1)

    if Enum.any?(items, &(item_type(&1) in [:handoff_history, :handoff_message])) do
      project_structured_handoff_contents(items)
    else
      project_contents_for_item_types(message, user_input_item_types())
    end
  end

  @doc """
  Projects the text portion of user input as it will be sent to a model.
  """
  def project_user_input_text(message) do
    message
    |> project_user_input_contents()
    |> Enum.filter(&(content_kind(&1) == :text))
    |> Enum.map(&to_string(Map.get(&1, :content_text) || ""))
    |> Enum.join("")
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

  defp replace_empty_user_message(message) do
    if canonical_role(message) == "user" and user_message_empty?(message) do
      placeholder_user_message()
    else
      message
    end
  end

  defp ensure_user_boundaries([]), do: [placeholder_user_message()]

  defp ensure_user_boundaries(history) do
    history =
      if canonical_role(List.first(history)) == "user" do
        history
      else
        [placeholder_user_message() | history]
      end

    if canonical_role(List.last(history)) == "user" do
      history
    else
      history ++ [placeholder_user_message()]
    end
  end

  defp user_message_empty?(message) do
    content =
      if trace_message?(message) do
        project_user_input_contents(message)
      else
        case normalize_message(message) do
          %{"content" => content} -> content
          _other -> nil
        end
      end

    content_empty?(content)
  end

  defp content_empty?(nil), do: true
  defp content_empty?(content) when is_binary(content), do: String.trim(content) == ""
  defp content_empty?(content) when is_list(content), do: Enum.all?(content, &content_empty?/1)

  defp content_empty?(%{} = content) do
    cond do
      content_kind(content) == :text -> content |> Map.get(:content_text) |> content_empty?()
      content_kind(content) == :media -> false
      Map.has_key?(content, "text") -> content |> Map.get("text") |> content_empty?()
      Map.has_key?(content, :text) -> content |> Map.get(:text) |> content_empty?()
      Map.has_key?(content, "content") -> content |> Map.get("content") |> content_empty?()
      Map.has_key?(content, :content) -> content |> Map.get(:content) |> content_empty?()
      true -> false
    end
  end

  defp content_empty?(content), do: content |> to_string() |> String.trim() == ""

  defp canonical_role(message) do
    case message_role(message) do
      nil ->
        case normalize_message(message) do
          %{"role" => role} -> role
          _other -> nil
        end

      role ->
        role
    end
  end

  defp placeholder_user_message do
    %{role: :user, content: @missing_user_message_placeholder}
  end

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

  defp project_structured_handoff_contents(items) do
    history =
      items
      |> Enum.filter(&(item_type(&1) == :handoff_history))
      |> Enum.flat_map(fn item ->
        item
        |> contents()
        |> Enum.sort_by(&sort_seq/1)
        |> Enum.filter(&(content_kind(&1) == :text))
        |> Enum.map(&history_entry_from_content/1)
      end)

    handoff_message =
      items
      |> Enum.filter(&(item_type(&1) == :handoff_message))
      |> Enum.map(&item_text/1)
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.join("\n\n")

    media =
      items
      |> Enum.filter(&(item_type(&1) in [:handoff_history, :handoff_message]))
      |> Enum.flat_map(&media_contents_for_item/1)

    prompt = HandoffRolloff.render_prompt(history, handoff_message)
    text_content = %{kind: :text, sequence: 1, content_text: prompt, content_json: nil}

    [text_content] ++
      (media
       |> Enum.with_index(2)
       |> Enum.map(fn {content, sequence} -> Map.put(content, :sequence, sequence) end))
  end

  defp history_entry_from_content(content) do
    metadata =
      case Map.get(content, :content_json) do
        %{} = value -> Map.new(value)
        _other -> %{}
      end

    %{
      kind: history_entry_kind(metadata_value(metadata, "entry_kind")),
      role: history_entry_role(metadata_value(metadata, "role")),
      timestamp: metadata_value(metadata, "created_at"),
      omitted_count: metadata_value(metadata, "omitted_count"),
      text: to_string(Map.get(content, :content_text) || "")
    }
  end

  defp metadata_value(metadata, "entry_kind"),
    do: Map.get(metadata, "entry_kind", Map.get(metadata, :entry_kind))

  defp metadata_value(metadata, "role"), do: Map.get(metadata, "role", Map.get(metadata, :role))

  defp metadata_value(metadata, "created_at"),
    do: Map.get(metadata, "created_at", Map.get(metadata, :created_at))

  defp metadata_value(metadata, "omitted_count"),
    do: Map.get(metadata, "omitted_count", Map.get(metadata, :omitted_count))

  defp history_entry_kind("continuation"), do: :continuation
  defp history_entry_kind("omission"), do: :omission
  defp history_entry_kind(_kind), do: :message

  defp history_entry_role("assistant"), do: :assistant
  defp history_entry_role(_role), do: :user
end
