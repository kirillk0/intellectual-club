defmodule IntellectualClub.Chat.MessageContentFts do
  @moduledoc """
  Helpers for SQLite FTS5 search over `chat_message_contents.content_text`.
  """

  import Ecto.Query

  @enforce_keys [:match, :tokens]
  defstruct [:match, :tokens]

  @type t :: %__MODULE__{
          match: String.t(),
          tokens: list(String.t())
        }

  @token_regex ~r/[\p{L}\p{N}_]+/u
  @searchable_item_types ["input", "answer"]

  @spec build(String.t() | nil) :: t() | nil
  def build(term) when is_binary(term) do
    tokens = tokenize(term)

    case tokens do
      [] ->
        nil

      tokens ->
        %__MODULE__{
          tokens: tokens,
          match: Enum.map_join(tokens, " AND ", &~s("#{escape_token(&1)}"*))
        }
    end
  end

  def build(nil), do: nil
  def build(other), do: other |> to_string() |> build()

  @spec match_query(t() | nil) :: String.t() | nil
  def match_query(%__MODULE__{match: match}), do: match
  def match_query(_other), do: nil

  @spec tokens(t() | nil) :: list(String.t())
  def tokens(%__MODULE__{tokens: tokens}), do: tokens
  def tokens(_other), do: []

  @spec build_snippet(String.t() | nil, t() | nil, pos_integer()) :: String.t() | nil
  def build_snippet(text, query, radius \\ 60)

  def build_snippet(text, %__MODULE__{} = query, radius) when is_integer(radius) do
    text = to_string(text || "")

    if text == "" do
      nil
    else
      case first_matching_span(text, query.tokens) do
        nil ->
          nil

        {match_start_bytes, match_len_bytes} ->
          snippet_from_span(text, match_start_bytes, match_len_bytes, radius)
      end
    end
  end

  def build_snippet(_text, _query, _radius), do: nil

  @spec modify_message_query(Ash.Query.t(), Ecto.Query.t()) ::
          {:ok, Ecto.Query.t()} | {:error, term()}
  def modify_message_query(ash_query, data_layer_query) do
    case Ash.Query.get_argument(ash_query, :fts_match) do
      match when is_binary(match) and match != "" ->
        {:ok,
         data_layer_query
         |> join(:inner, [message, ...], step in "chat_message_steps",
           as: :message_content_fts_step,
           on: field(step, :chat_message_id) == message.id
         )
         |> join(:inner, [message_content_fts_step: step], item in "chat_message_items",
           as: :message_content_fts_item,
           on: field(item, :chat_message_step_id) == field(step, :id)
         )
         |> join(:inner, [message_content_fts_item: item], content in "chat_message_contents",
           as: :message_content_fts_content,
           on: field(content, :chat_message_item_id) == field(item, :id)
         )
         |> where(
           [message_content_fts_item: item, message_content_fts_content: content],
           field(item, :type) in ^@searchable_item_types and
             field(content, :kind) == "text" and
             fragment(
               """
               ? IN (
                 SELECT rowid
                 FROM chat_message_contents_fts
                 WHERE chat_message_contents_fts MATCH ?
               )
               """,
               field(content, :id),
               ^match
             )
         )
         |> distinct(true)}

      _other ->
        {:ok, data_layer_query}
    end
  end

  @spec modify_content_query(Ash.Query.t(), Ecto.Query.t()) ::
          {:ok, Ecto.Query.t()} | {:error, term()}
  def modify_content_query(ash_query, data_layer_query) do
    case Ash.Query.get_argument(ash_query, :fts_match) do
      match when is_binary(match) and match != "" ->
        {:ok,
         where(
           data_layer_query,
           [content],
           fragment(
             """
             ? IN (
               SELECT rowid
               FROM chat_message_contents_fts
               WHERE chat_message_contents_fts MATCH ?
             )
             """,
             content.id,
             ^match
           )
         )}

      _other ->
        {:ok, data_layer_query}
    end
  end

  defp tokenize(term) when is_binary(term) do
    term
    |> String.trim()
    |> then(&Regex.scan(@token_regex, &1))
    |> List.flatten()
    |> Enum.reduce({MapSet.new(), []}, fn token, {seen, acc} ->
      normalized = String.downcase(token)

      if MapSet.member?(seen, normalized) do
        {seen, acc}
      else
        {MapSet.put(seen, normalized), [normalized | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp escape_token(token) when is_binary(token) do
    String.replace(token, "\"", "\"\"")
  end

  defp first_matching_span(text, tokens) when is_binary(text) and is_list(tokens) do
    Regex.scan(@token_regex, text, return: :index)
    |> Enum.reduce_while(nil, fn
      [{match_start_bytes, match_len_bytes}], _acc ->
        token_text = binary_part(text, match_start_bytes, match_len_bytes)
        normalized = String.downcase(token_text)

        if Enum.any?(tokens, &String.starts_with?(normalized, &1)) do
          {:halt, {match_start_bytes, match_len_bytes}}
        else
          {:cont, nil}
        end

      _other, _acc ->
        {:cont, nil}
    end)
  end

  defp snippet_from_span(text, match_start_bytes, match_len_bytes, radius)
       when is_binary(text) and is_integer(match_start_bytes) and is_integer(match_len_bytes) do
    prefix_len =
      if match_start_bytes <= 0 do
        0
      else
        text
        |> binary_part(0, match_start_bytes)
        |> String.length()
      end

    match_end_bytes = match_start_bytes + match_len_bytes

    match_end_len =
      if match_end_bytes <= 0 do
        0
      else
        text
        |> binary_part(0, match_end_bytes)
        |> String.length()
      end

    total_len = String.length(text)
    start_idx = max(0, prefix_len - radius)
    end_idx = min(total_len, match_end_len + radius)

    snippet = String.slice(text, start_idx, end_idx - start_idx)
    prefix = if start_idx > 0, do: "...", else: ""
    suffix = if end_idx < total_len, do: "...", else: ""

    prefix <> snippet <> suffix
  end
end
