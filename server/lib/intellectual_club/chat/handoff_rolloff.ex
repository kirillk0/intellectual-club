defmodule IntellectualClub.Chat.HandoffRolloff do
  @moduledoc """
  Builds a compaction checkpoint from the original canonical conversation.

  Checkpoint copies are excluded from later archives. An initial checkpoint seed
  is expanded only when no original prefix exists. The selected branch and any
  linked-fork response boundaries remain fixed and actor-authorized.
  """

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ForkHistory
  alias IntellectualClub.TokenCounter

  @budget_tokens 20_000
  @assistant_soft_limit 200
  @massive_user_limit 200
  @massive_assistant_limit 50

  @type artifact_payload :: %{
          required(:filename) => String.t(),
          required(:mime_type) => String.t(),
          required(:payload) => binary()
        }

  @type result :: %{
          required(:history) => [map()],
          required(:handoff_message) => String.t(),
          required(:artifact) => artifact_payload(),
          required(:strategy) => atom(),
          required(:token_count) => non_neg_integer()
        }

  @doc """
  Returns budgeted history, the full display summary and a cumulative archive.

  `source_message_id` includes the persisted portion of a generating message.
  The archive is always attached, even when the history fits without truncation.
  Summary truncation remains a last-resort provider-prompt policy, not a change
  to the stored `handoff_message`; use `render_prompt/2` for model input.
  """
  @spec build(Chat.t(), map(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def build(%Chat{} = source, actor, summary, opts \\ [])
      when is_binary(summary) and is_list(opts) do
    with {:ok, entries} <- conversation_entries(source, actor, opts) do
      full_document = previous_conversation_document(entries, :full)

      entries
      |> build_candidates(summary, full_document)
      |> select_candidate(summary)
    end
  end

  def budget_tokens, do: @budget_tokens

  defp build_candidates(entries, summary, full_document) do
    [
      candidate(entries, summary, :full, full_document),
      candidate(entries, summary, :assistant_200, full_document),
      candidate(entries, summary, :massive, full_document)
    ]
  end

  defp candidate(entries, summary, strategy, full_document) do
    history = Enum.map(entries, &truncate_entry(&1, strategy))
    text = render_full_prompt(history, summary)

    %{
      history: history,
      handoff_message: summary,
      artifact: artifact_payload(full_document),
      strategy: strategy,
      token_count: TokenCounter.estimate(text),
      entries: entries
    }
  end

  defp select_candidate(candidates, summary) do
    case Enum.find(candidates, &(Map.get(&1, :token_count) <= @budget_tokens)) do
      nil ->
        entries = candidates |> List.first() |> Map.fetch!(:entries)
        full_document = previous_conversation_document(entries, :full)
        hard_middle_out(entries, summary, full_document)

      candidate ->
        {:ok, public_candidate(candidate)}
    end
  end

  defp hard_middle_out(entries, summary, full_document) do
    entries = Enum.map(entries, &truncate_entry(&1, :massive))
    first_entry = List.first(entries)
    tail_entries = entries |> Enum.drop(1) |> Enum.reverse()

    {_prompt_summary, included_tail} =
      fit_hard_middle_out(first_entry, tail_entries, summary, [])

    omitted_count =
      max(length(entries) - length(included_tail) - if(first_entry, do: 1, else: 0), 0)

    history = hard_history(first_entry, included_tail, omitted_count)
    text = render_prompt(history, summary)

    candidate = %{
      history: history,
      handoff_message: summary,
      artifact: artifact_payload(full_document),
      strategy: :hard_middle_out,
      token_count: TokenCounter.estimate(text)
    }

    {:ok, public_candidate(candidate)}
  end

  defp fit_hard_middle_out(first_entry, tail_entries, summary, included_tail) do
    omitted_count = omitted_count(first_entry, tail_entries, included_tail)
    history = hard_history(first_entry, included_tail, omitted_count)
    summary = fit_summary(summary, history)

    Enum.reduce_while(tail_entries, {summary, included_tail}, fn entry, {summary, included} ->
      next_included = [entry | included]
      next_omitted = omitted_count(first_entry, tail_entries, next_included)

      history = hard_history(first_entry, next_included, next_omitted)
      text = render_full_prompt(history, summary)

      if TokenCounter.estimate(text) <= @budget_tokens do
        {:cont, {summary, next_included}}
      else
        {:halt, {summary, included}}
      end
    end)
  end

  defp omitted_count(nil, tail_entries, included_tail) do
    max(length(tail_entries) - length(included_tail), 0)
  end

  defp omitted_count(_first_entry, tail_entries, included_tail) do
    max(length(tail_entries) - length(included_tail), 0)
  end

  defp fit_summary(summary, history) do
    text = render_full_prompt(history, summary)

    if TokenCounter.estimate(text) <= @budget_tokens do
      summary
    else
      empty_summary_text = render_full_prompt(history, "")
      remaining = max(@budget_tokens - TokenCounter.estimate(empty_summary_text), 0)
      trim_summary_to_budget(truncate_text(summary, remaining), history)
    end
  end

  defp trim_summary_to_budget(summary, history) do
    if TokenCounter.estimate(render_full_prompt(history, summary)) <= @budget_tokens do
      summary
    else
      next_limit = max(TokenCounter.estimate(summary) - 50, 0)

      if next_limit == 0 do
        truncate_text(summary, next_limit)
      else
        trim_summary_to_budget(truncate_text(summary, next_limit), history)
      end
    end
  end

  defp public_candidate(candidate) do
    candidate
    |> Map.take([:history, :handoff_message, :artifact, :strategy, :token_count])
  end

  defp artifact_payload(full_document) do
    %{
      filename: "full_conversation.md",
      mime_type: "text/markdown",
      payload: full_document
    }
  end

  @doc """
  Renders structured handoff data for model input without changing persisted display text.

  The existing 20,000-token budget still applies: an oversized summary is fitted
  to the remaining prompt budget. `build/4` retains the complete supplied summary
  for display and persistence instead of returning this provider-only truncation.
  """
  @spec render_prompt([map()], String.t()) :: String.t()
  def render_prompt(history, summary) when is_list(history) do
    summary = fit_summary(to_string(summary || ""), history)
    render_full_prompt(history, summary)
  end

  defp render_full_prompt(history, summary) do
    [
      "History",
      "",
      Enum.map_join(history, "\n", &entry_block/1),
      "",
      "Handoff message",
      "",
      String.trim(to_string(summary || ""))
    ]
    |> Enum.join("\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp hard_history(first_entry, tail_entries, omitted_count) do
    []
    |> maybe_append(first_entry)
    |> maybe_append(omission_entry(omitted_count))
    |> Kernel.++(tail_entries)
  end

  defp previous_conversation_document(entries, strategy) do
    body =
      entries
      |> Enum.map(&truncate_entry(&1, strategy))
      |> Enum.map_join("\n", &entry_block/1)

    ["# Previous conversation", "", body]
    |> Enum.join("\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp maybe_append(values, nil), do: values
  defp maybe_append(values, value), do: values ++ [value]

  defp omission_entry(count) when is_integer(count) and count > 0 do
    %{
      kind: :omission,
      omitted_count: count,
      text: "[... omitted #{count} middle messages; see attached full_conversation.md ...]"
    }
  end

  defp omission_entry(_count), do: nil

  defp truncate_entry(%{kind: :omission} = entry, _strategy), do: entry

  defp truncate_entry(%{role: :assistant, text: text} = entry, :assistant_200) do
    %{entry | text: truncate_text(text, @assistant_soft_limit)}
  end

  defp truncate_entry(%{role: :assistant, text: text} = entry, :massive) do
    %{entry | text: truncate_text(text, @massive_assistant_limit)}
  end

  defp truncate_entry(%{role: :user, text: text} = entry, :massive) do
    %{entry | text: truncate_text(text, @massive_user_limit)}
  end

  defp truncate_entry(entry, _strategy), do: entry

  defp truncate_text(text, limit) when is_integer(limit) and limit > 0 do
    text = to_string(text || "")

    if TokenCounter.estimate(text) <= limit do
      text
    else
      suffix = "\n\n[truncated to #{limit} tokens]"
      suffix_tokens = TokenCounter.estimate(suffix)
      allowed_tokens = max(limit - suffix_tokens, 0)
      allowed_bytes = floor(allowed_tokens * 3.5)

      text
      |> valid_binary_prefix(allowed_bytes)
      |> String.trim_trailing()
      |> Kernel.<>(suffix)
    end
  end

  defp truncate_text(_text, _limit), do: "[truncated to 0 tokens]"

  defp valid_binary_prefix(text, allowed_bytes) when allowed_bytes <= 0 do
    _ = text
    ""
  end

  defp valid_binary_prefix(text, allowed_bytes) do
    text = to_string(text || "")
    prefix_size = min(byte_size(text), allowed_bytes)
    do_valid_binary_prefix(binary_part(text, 0, prefix_size))
  end

  defp do_valid_binary_prefix(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> byte_size()
      |> case do
        0 -> ""
        size -> binary |> binary_part(0, size - 1) |> do_valid_binary_prefix()
      end
    end
  end

  defp entry_block(%{kind: :omission, text: text}) do
    [text, "", "___", ""]
    |> Enum.join("\n")
  end

  defp entry_block(%{role: role, timestamp: timestamp, text: text}) do
    [
      "**#{role_text(role)}** (#{timestamp_text(timestamp)}):",
      String.trim(to_string(text || "")),
      "",
      "___",
      ""
    ]
    |> Enum.join("\n")
  end

  defp role_text(:user), do: "user"
  defp role_text(:assistant), do: "assistant"
  defp role_text(role), do: to_string(role || "message")

  defp timestamp_text(nil), do: "unknown"

  defp timestamp_text(%DateTime{} = value) do
    value
    |> utc_datetime()
    |> Calendar.strftime("%Y-%m-%d %H:%MZ")
  end

  defp timestamp_text(%NaiveDateTime{} = value) do
    Calendar.strftime(value, "%Y-%m-%d %H:%MZ")
  end

  defp timestamp_text(value) when is_binary(value) do
    with {:error, _reason} <- DateTime.from_iso8601(value),
         {:error, _reason} <- NaiveDateTime.from_iso8601(value) do
      value
      |> String.replace("T", " ")
      |> case do
        <<prefix::binary-size(16), _rest::binary>> -> prefix <> "Z"
        other -> other
      end
    else
      {:ok, %DateTime{} = datetime, _offset} -> timestamp_text(datetime)
      {:ok, %NaiveDateTime{} = datetime} -> timestamp_text(datetime)
    end
  end

  defp timestamp_text(value), do: value |> to_string() |> timestamp_text()

  defp utc_datetime(%DateTime{} = value) do
    case DateTime.shift_zone(value, "Etc/UTC") do
      {:ok, shifted} -> shifted
      {:error, _reason} -> value
    end
  end

  defp conversation_entries(%Chat{} = source, actor, opts) do
    exclude_message_ids =
      opts
      |> Keyword.get(:exclude_message_ids, [])
      |> List.wrap()
      |> Enum.filter(&is_integer/1)
      |> MapSet.new()

    with {:ok, target_message_id} <- target_message_id(source, actor, opts),
         {:ok, branch} <-
           ForkHistory.effective_branch(source, target_message_id, actor,
             load: message_load(),
             strict?: true
           ) do
      entries =
        branch
        |> Enum.with_index()
        |> Enum.flat_map(fn {message, index} ->
          if MapSet.member?(exclude_message_ids, message.id) do
            []
          else
            message_entries(message, index == 0)
          end
        end)

      {:ok, entries}
    end
  rescue
    error -> {:error, error}
  end

  defp target_message_id(source, actor, opts) do
    case Keyword.fetch(opts, :source_message_id) do
      {:ok, message_id} ->
        {:ok, message_id}

      :error ->
        with {:ok, current} <- Ash.get(Chat, source.id, actor: actor, authorize?: true) do
          {:ok, current.last_message_id}
        end
    end
  end

  defp message_entries(%ChatMessage{} = message, root?) do
    seed = if root?, do: checkpoint_seed_entries(message), else: []

    case message.role do
      :user ->
        case message_text(message, [:input]) do
          "" ->
            seed

          text ->
            seed ++ [%{kind: :message, role: :user, timestamp: message.created_at, text: text}]
        end

      :assistant ->
        seed ++ message_item_entries(message, [:answer, :artifact, :steering])

      _other ->
        []
    end
  end

  defp checkpoint_seed_entries(%ChatMessage{} = message) do
    # Only an initial seed has no originals to recover. Later checkpoints in
    # this same root message are copies too, not additional conversation.
    items =
      message
      |> Map.get(:steps, [])
      |> ordered()
      |> Enum.flat_map(fn step -> step |> Map.get(:items, []) |> ordered() end)
      |> Enum.take_while(&(Map.get(&1, :type) in [:handoff_history, :handoff_message]))
      |> Enum.take(2)

    Enum.flat_map(items, fn item ->
      case Map.get(item, :type) do
        :handoff_history ->
          item
          |> Map.get(:contents, [])
          |> ordered()
          |> Enum.filter(&(Map.get(&1, :kind) == :text))
          |> Enum.map(&structured_history_entry(&1, message.created_at))
          |> Enum.reject(&(String.trim(Map.get(&1, :text, "")) == ""))

        :handoff_message ->
          case item_text(message, item) do
            "" -> []
            text -> [%{kind: :message, role: :user, timestamp: message.created_at, text: text}]
          end
      end
    end)
  end

  defp structured_history_entry(content, fallback_timestamp) do
    metadata =
      case Map.get(content, :content_json) do
        %{} = value -> Map.new(value)
        _other -> %{}
      end

    kind = metadata_value(metadata, "entry_kind")

    %{
      kind: structured_entry_kind(kind),
      role: structured_entry_role(metadata_value(metadata, "role")),
      timestamp: metadata_value(metadata, "created_at") || fallback_timestamp,
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

  defp structured_entry_kind("omission"), do: :omission
  defp structured_entry_kind(_kind), do: :message

  defp structured_entry_role("assistant"), do: :assistant
  defp structured_entry_role(_role), do: :user

  defp message_item_entries(%ChatMessage{} = message, item_types) when is_list(item_types) do
    message
    |> Map.get(:steps, [])
    |> ordered()
    |> Enum.flat_map(fn step ->
      step
      |> Map.get(:items, [])
      |> ordered()
      |> Enum.filter(&(Map.get(&1, :type) in item_types))
      |> Enum.map(&{Map.get(&1, :type), item_text(message, &1)})
    end)
    |> Enum.reject(fn {_type, text} -> String.trim(text) == "" end)
    |> Enum.map(fn {type, text} ->
      role = if type == :steering, do: :user, else: :assistant
      %{kind: :message, role: role, timestamp: message.created_at, text: text}
    end)
  end

  defp message_text(%ChatMessage{} = message, item_types) when is_list(item_types) do
    message
    |> Map.get(:steps, [])
    |> ordered()
    |> Enum.flat_map(fn step ->
      step
      |> Map.get(:items, [])
      |> ordered()
      |> Enum.filter(&(Map.get(&1, :type) in item_types))
      |> Enum.map(&item_text(message, &1))
    end)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp item_text(%ChatMessage{} = message, item) do
    item
    |> Map.get(:contents, [])
    |> ordered()
    |> Enum.flat_map(fn content ->
      case Map.get(content, :kind) do
        :text ->
          [to_string(Map.get(content, :content_text) || "")]

        :media ->
          [media_reference(message, content)]

        _other ->
          []
      end
    end)
    |> Enum.join("")
    |> String.trim()
  end

  defp media_reference(%ChatMessage{id: message_id}, content) do
    file = loaded_file(content)

    file_external_id = Map.get(file, :external_id)
    filename = Map.get(file, :filename) || "attachment"
    mime_type = Map.get(file, :mime_type) || "application/octet-stream"
    size_bytes = Map.get(file, :size_bytes) || 0
    content_id = Map.get(content, :id)

    url =
      if is_integer(message_id) and is_integer(content_id) do
        "/api/bff/chat-messages/#{message_id}/contents/#{content_id}/file"
      else
        ""
      end

    [
      "\n[Attached file",
      "file_id=#{file_external_id || ""}",
      "filename=#{inspect(filename)}",
      "mime_type=#{inspect(mime_type)}",
      "size_bytes=#{size_bytes}",
      "url=#{inspect(url)}]"
    ]
    |> Enum.join(" ")
  end

  defp loaded_file(content) do
    case Map.get(content, :file) do
      %Ash.NotLoaded{} -> %{}
      %{} = file -> file
      _other -> %{}
    end
  end

  defp ordered(values) when is_list(values) do
    Enum.sort_by(values, fn value ->
      {Map.get(value, :sequence) || 0, Map.get(value, :id) || 0}
    end)
  end

  defp ordered(_values), do: []

  defp message_load do
    [
      steps: [
        :id,
        :sequence,
        items: [
          :id,
          :sequence,
          :type,
          contents: [
            :id,
            :sequence,
            :kind,
            :content_text,
            :content_json,
            :file_id,
            file: [:id, :external_id, :filename, :mime_type, :size_bytes, :sha256]
          ]
        ]
      ]
    ]
  end
end
