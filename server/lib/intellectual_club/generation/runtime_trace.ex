defmodule IntellectualClub.Generation.RuntimeTrace do
  @moduledoc """
  In-memory accumulator for a single runtime `ChatMessageStep`.

  Provider adapters emit canonical trace events (step/item/content) and the
  generation worker applies them to this structure. The worker later persists
  the full step snapshot to the database in one batch.
  """

  defmodule Step do
    @moduledoc false

    defstruct [
      :id,
      :sequence,
      :started_at,
      :status,
      :raw_request,
      :raw_response,
      :response_final,
      :input_tokens,
      :output_tokens,
      :cached_input_tokens,
      :reasoning_tokens,
      :cost,
      items_by_key: %{}
    ]
  end

  defmodule Item do
    @moduledoc false

    defstruct [
      :key,
      :sequence,
      :type,
      contents_by_sequence: %{}
    ]
  end

  defmodule Content do
    @moduledoc false

    defstruct [
      :external_id,
      :sequence,
      :kind,
      :file_id,
      :file,
      :content_text,
      :content_json
    ]
  end

  @type item_type ::
          :input | :answer | :reasoning | :tool_call | :tool_result | :artifact | :error | :other
  @type content_kind :: :text | :opaque | :media

  @type trace_event ::
          {:ensure_item, String.t(), item_type(), integer() | nil}
          | {:append_text, String.t(), item_type(), integer(), String.t()}
          | {:set_text, String.t(), item_type(), integer(), String.t()}
          | {:set_opaque, String.t(), item_type(), integer(), map() | nil}
          | {:set_media, String.t(), item_type(), integer(), map()}
          | {:set_step_raw_request, map()}
          | {:set_step_raw_response, map() | nil}
          | {:set_step_usage, map() | nil}
          | {:set_step_response_final, boolean()}

  @spec new_step(keyword()) :: Step.t()
  def new_step(opts \\ []) do
    %Step{
      id: Keyword.get(opts, :id, nil),
      sequence: Keyword.get(opts, :sequence, 1),
      started_at: Keyword.get(opts, :started_at, DateTime.utc_now()),
      status: Keyword.get(opts, :status, :waiting_provider),
      raw_request: Keyword.get(opts, :raw_request, %{}),
      raw_response: Keyword.get(opts, :raw_response, nil),
      response_final: Keyword.get(opts, :response_final, false),
      input_tokens: Keyword.get(opts, :input_tokens, nil),
      output_tokens: Keyword.get(opts, :output_tokens, nil),
      cached_input_tokens: Keyword.get(opts, :cached_input_tokens, nil),
      reasoning_tokens: Keyword.get(opts, :reasoning_tokens, nil),
      cost: Keyword.get(opts, :cost, nil),
      items_by_key: %{}
    }
  end

  @spec apply_event(Step.t(), trace_event()) :: Step.t()
  def apply_event(%Step{} = step, {:ensure_item, item_key, item_type, item_sequence}) do
    ensure_item(step, item_key, item_type, item_sequence)
  end

  def apply_event(%Step{} = step, {:append_text, item_key, item_type, content_sequence, delta}) do
    step
    |> ensure_item(item_key, item_type, nil)
    |> update_item(item_key, fn item ->
      content =
        ensure_content(item, content_sequence, :text)
        |> append_text(delta)

      put_content(item, content)
    end)
  end

  def apply_event(%Step{} = step, {:set_text, item_key, item_type, content_sequence, text}) do
    step
    |> ensure_item(item_key, item_type, nil)
    |> update_item(item_key, fn item ->
      content =
        ensure_content(item, content_sequence, :text)
        |> set_text(text)

      put_content(item, content)
    end)
  end

  def apply_event(%Step{} = step, {:set_opaque, item_key, item_type, content_sequence, json}) do
    step
    |> ensure_item(item_key, item_type, nil)
    |> update_item(item_key, fn item ->
      content =
        ensure_content(item, content_sequence, :opaque)
        |> set_opaque(json)

      put_content(item, content)
    end)
  end

  def apply_event(%Step{} = step, {:set_media, item_key, item_type, content_sequence, media})
      when is_map(media) do
    step
    |> ensure_item(item_key, item_type, nil)
    |> update_item(item_key, fn item ->
      content =
        ensure_content(item, content_sequence, :media)
        |> set_media(media)

      put_content(item, content)
    end)
  end

  def apply_event(%Step{} = step, {:set_step_raw_request, raw_request})
      when is_map(raw_request) do
    %{step | raw_request: raw_request}
  end

  def apply_event(%Step{} = step, {:set_step_raw_response, raw_response}) do
    %{step | raw_response: raw_response}
  end

  def apply_event(%Step{} = step, {:set_step_usage, nil}), do: step

  def apply_event(%Step{} = step, {:set_step_usage, usage}) when is_map(usage) do
    %{
      step
      | input_tokens: Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens"),
        output_tokens: Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens"),
        cached_input_tokens:
          Map.get(usage, :cached_input_tokens) || Map.get(usage, "cached_input_tokens") ||
            get_nested_usage_value(usage, [:input_tokens_details, :cached_tokens]) ||
            get_nested_usage_value(usage, ["input_tokens_details", "cached_tokens"]) ||
            get_nested_usage_value(usage, [:prompt_tokens_details, :cached_tokens]) ||
            get_nested_usage_value(usage, ["prompt_tokens_details", "cached_tokens"]),
        reasoning_tokens:
          Map.get(usage, :reasoning_tokens) || Map.get(usage, "reasoning_tokens") ||
            get_nested_usage_value(usage, [:output_tokens_details, :reasoning_tokens]) ||
            get_nested_usage_value(usage, ["output_tokens_details", "reasoning_tokens"]) ||
            get_nested_usage_value(usage, [:completion_tokens_details, :reasoning_tokens]) ||
            get_nested_usage_value(usage, ["completion_tokens_details", "reasoning_tokens"]),
        cost: Map.get(usage, :cost) || Map.get(usage, "cost")
    }
  end

  def apply_event(%Step{} = step, {:set_step_usage, _other}), do: step

  def apply_event(%Step{} = step, {:set_step_response_final, value}) when is_boolean(value) do
    %{step | response_final: value}
  end

  def apply_event(%Step{} = step, _unknown), do: step

  @spec snapshot(Step.t()) :: map()
  def snapshot(%Step{} = step) do
    created_at = if step.started_at, do: DateTime.to_iso8601(step.started_at), else: nil

    %{
      id: step.id || -1,
      sequence: step.sequence || 1,
      created_at: created_at,
      status: status_string(step.status),
      response_final: step.response_final || false,
      input_tokens: step.input_tokens,
      output_tokens: step.output_tokens,
      cached_input_tokens: step.cached_input_tokens,
      reasoning_tokens: step.reasoning_tokens,
      cost: step.cost,
      items:
        step.items_by_key
        |> Map.values()
        |> Enum.sort_by(& &1.sequence)
        |> Enum.map(&item_snapshot/1)
    }
  end

  @spec persistable(Step.t()) :: map()
  def persistable(%Step{} = step) do
    %{
      sequence: step.sequence || 1,
      started_at: step.started_at,
      status: step.status || :waiting_provider,
      raw_request: step.raw_request || %{},
      raw_response: step.raw_response,
      response_final: step.response_final || false,
      input_tokens: step.input_tokens,
      output_tokens: step.output_tokens,
      cached_input_tokens: step.cached_input_tokens,
      reasoning_tokens: step.reasoning_tokens,
      cost: step.cost,
      items:
        step.items_by_key
        |> Map.values()
        |> Enum.sort_by(& &1.sequence)
        |> Enum.map(&item_persistable/1)
    }
  end

  @spec text_for_item_type(Step.t(), item_type()) :: String.t()
  def text_for_item_type(%Step{} = step, item_type) when is_atom(item_type) do
    step.items_by_key
    |> Map.values()
    |> Enum.sort_by(& &1.sequence)
    |> Enum.filter(&(&1.type == item_type))
    |> Enum.map(&item_text/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  def text_for_item_type(%Step{} = _step, _type), do: ""

  defp status_string(nil), do: nil
  defp status_string(value) when is_atom(value), do: Atom.to_string(value)
  defp status_string(value) when is_binary(value), do: value
  defp status_string(value), do: to_string(value)

  defp get_nested_usage_value(usage, [outer_key, inner_key]) when is_map(usage) do
    usage
    |> Map.get(outer_key)
    |> case do
      nested when is_map(nested) -> Map.get(nested, inner_key)
      _other -> nil
    end
  end

  defp get_nested_usage_value(_usage, _path), do: nil

  defp ensure_item(%Step{} = step, item_key, item_type, item_sequence) do
    existing = Map.get(step.items_by_key, item_key)

    cond do
      is_struct(existing, Item) ->
        item =
          existing
          |> maybe_set_item_sequence(item_sequence)
          |> Map.put(:type, item_type)

        %{step | items_by_key: Map.put(step.items_by_key, item_key, item)}

      true ->
        sequence =
          cond do
            is_integer(item_sequence) and item_sequence > 0 -> item_sequence
            true -> next_item_sequence(step.items_by_key)
          end

        item = %Item{
          key: item_key,
          type: item_type,
          sequence: sequence,
          contents_by_sequence: %{}
        }

        %{step | items_by_key: Map.put(step.items_by_key, item_key, item)}
    end
  end

  defp maybe_set_item_sequence(%Item{} = item, nil), do: item

  defp maybe_set_item_sequence(%Item{} = item, value) when is_integer(value) and value > 0 do
    %{item | sequence: value}
  end

  defp maybe_set_item_sequence(%Item{} = item, _other), do: item

  defp update_item(%Step{} = step, item_key, fun) when is_function(fun, 1) do
    case Map.get(step.items_by_key, item_key) do
      %Item{} = item ->
        %{step | items_by_key: Map.put(step.items_by_key, item_key, fun.(item))}

      _ ->
        step
    end
  end

  defp next_item_sequence(items_by_key) when is_map(items_by_key) do
    items_by_key
    |> Map.values()
    |> Enum.map(& &1.sequence)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp ensure_content(%Item{} = item, content_sequence, kind)
       when is_integer(content_sequence) and content_sequence > 0 and is_atom(kind) do
    case Map.get(item.contents_by_sequence, content_sequence) do
      %Content{} = content ->
        %{content | kind: kind}

      _ ->
        %Content{
          external_id: Ash.UUID.generate(),
          sequence: content_sequence,
          kind: kind,
          file_id: nil,
          file: nil,
          content_text: "",
          content_json: nil
        }
    end
  end

  defp ensure_content(%Item{} = item, _seq, kind) when is_atom(kind) do
    seq = next_content_sequence(item.contents_by_sequence)

    %Content{
      external_id: Ash.UUID.generate(),
      sequence: seq,
      kind: kind,
      file_id: nil,
      file: nil,
      content_text: "",
      content_json: nil
    }
  end

  defp next_content_sequence(contents_by_sequence) when is_map(contents_by_sequence) do
    contents_by_sequence
    |> Map.keys()
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp append_text(%Content{} = content, delta) do
    delta = to_string(delta || "")

    if delta == "" do
      content
    else
      %{content | content_text: to_string(content.content_text || "") <> delta}
    end
  end

  defp set_text(%Content{} = content, text) do
    %{content | content_text: to_string(text || "")}
  end

  defp set_opaque(%Content{} = content, json) do
    %{content | content_json: json}
  end

  defp set_media(%Content{} = content, media) when is_map(media) do
    file =
      media
      |> Map.get(:file, Map.get(media, "file", %{}))
      |> case do
        %{} = file -> Map.new(file)
        _other -> %{}
      end

    %{
      content
      | external_id:
          Map.get(media, :external_id, Map.get(media, "external_id")) ||
            content.external_id || Ash.UUID.generate(),
        file_id: Map.get(media, :file_id, Map.get(media, "file_id")) || content.file_id,
        file: if(map_size(file) == 0, do: content.file, else: file),
        content_text: "",
        content_json: nil
    }
  end

  defp put_content(%Item{} = item, %Content{} = content) do
    %{item | contents_by_sequence: Map.put(item.contents_by_sequence, content.sequence, content)}
  end

  defp item_snapshot(%Item{} = item) do
    %{
      id: -100 - (item.sequence || 0),
      sequence: item.sequence,
      type: Atom.to_string(item.type || :other),
      contents:
        item.contents_by_sequence
        |> Map.values()
        |> Enum.sort_by(& &1.sequence)
        |> Enum.map(fn content ->
          %{
            id: -20_000 - ((item.sequence || 0) * 1_000 + (content.sequence || 0)),
            external_id: content.external_id,
            sequence: content.sequence,
            kind: Atom.to_string(content.kind || :text),
            file_id: content.file_id,
            file: content.file,
            content_text: to_string(content.content_text || ""),
            content_json: content.content_json
          }
        end)
    }
  end

  defp item_persistable(%Item{} = item) do
    %{
      sequence: item.sequence,
      type: Atom.to_string(item.type || :other),
      contents:
        item.contents_by_sequence
        |> Map.values()
        |> Enum.sort_by(& &1.sequence)
        |> Enum.map(fn content ->
          %{
            external_id: content.external_id || Ash.UUID.generate(),
            sequence: content.sequence,
            kind: Atom.to_string(content.kind || :text),
            file_id: content.file_id,
            file: content.file,
            content_text: to_string(content.content_text || ""),
            content_json: content.content_json
          }
        end)
    }
  end

  defp item_text(%Item{} = item) do
    item.contents_by_sequence
    |> Map.values()
    |> Enum.sort_by(& &1.sequence)
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map_join("", fn content -> to_string(content.content_text || "") end)
  end
end
