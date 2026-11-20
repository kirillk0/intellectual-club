defmodule IntellectualClub.Chat.MessageText do
  @moduledoc """
  User-visible message text, prefix queries and contextual snippets.

  Matching uses the positional `simple` search vector of a whole stored message.
  A page reads its source text through Ash; tool traces, reasoning and opaque
  contents are not part of the visible text or its search vector.
  """

  alias IntellectualClub.Chat.ChatMessage
  require Ash.Query
  require Ash.Expr

  @snippet_radius 240
  @max_snippet_match 64
  @text_batch_size 200
  @max_terms 16
  @max_query_bytes 4096
  @max_term_bytes 256
  @token ~r/[\p{L}\p{N}][\p{L}\p{M}\p{N}]*/u
  @word_chars "[\\p{L}\\p{M}\\p{N}]"
  @separator "[^\\p{L}\\p{M}\\p{N}]++"

  @type search :: {:prefixes | :consecutive, nonempty_list(String.t())}

  @doc """
  Parses ordinary text, not PostgreSQL's tsquery language. In either mode at
  least one word must have three characters. Unordered AND ignores shorter
  words; consecutive search keeps them as whole words in their original slots.
  Over-limit inputs fail closed instead of becoming a wider partial query.
  """
  @spec search(String.t() | nil, boolean()) :: search() | :empty
  def search(query, ordered?) do
    case terms(query, ordered?) do
      [] -> :empty
      words when ordered? -> {:consecutive, words}
      words -> {:prefixes, words}
    end
  end

  @spec terms(String.t() | nil, boolean()) :: [String.t()]
  def terms(query, ordered?) when is_binary(query) and byte_size(query) <= @max_query_bytes do
    if String.valid?(query) do
      words =
        Regex.scan(@token, String.normalize(query, :nfc))
        |> Enum.map(fn [word] -> String.downcase(word) end)

      if Enum.all?(words, &(byte_size(&1) <= @max_term_bytes)) do
        words = if ordered?, do: words, else: words |> Enum.filter(&prefix?/1) |> Enum.uniq()
        if length(words) <= @max_terms and Enum.any?(words, &prefix?/1), do: words, else: []
      else
        []
      end
    else
      []
    end
  end

  def terms(_query, _ordered?), do: []

  defp prefix?(word), do: String.length(word) >= 3

  @doc "Builds a bound tsquery from tokenized words; operators are chosen by the application."
  @spec tsquery(search()) :: String.t()
  def tsquery({mode, words}) do
    operator = if mode == :consecutive, do: " <-> ", else: " & "

    Enum.map_join(words, operator, fn word ->
      # The tokenizer cannot emit quotes, backslashes or tsquery operators.
      "'" <> word <> "'" <> if(prefix?(word), do: ":*", else: "")
    end)
  end

  @doc "Applies the shared vector predicate to an authorized message query."
  def filter(query, search, opts \\ [])
  def filter(query, :empty, _opts), do: Ash.Query.filter(query, false)

  def filter(query, search, opts) do
    q = tsquery(search)
    owner = Keyword.get(opts, :owner_id)
    recent? = Keyword.get(opts, :recent?, false)
    query = if owner, do: Ash.Query.filter(query, owner_id == ^owner), else: query

    if recent? do
      # The outer Ash read already authorized this message. Look up only its
      # own derived row, never a hash of matches for every message in the DB.
      Ash.Query.filter(
        query,
        fragment(
          """
          EXISTS (SELECT 1 FROM chat_message_poll_revisions d
                   WHERE d.chat_message_id = ? AND d.search_owner_id = ?
                     AND pg_catalog.ts_match_vq(d.search_vector,
                           to_tsquery('pg_catalog.simple'::regconfig, ?::text)) OFFSET 0)
          """,
          id,
          owner_id,
          ^q
        )
      )
    else
      match =
        Ash.Expr.expr(
          fragment("? @@ to_tsquery('pg_catalog.simple'::regconfig, ?::text)", search_vector, ^q)
        )

      if owner do
        Ash.Query.filter(
          query,
          exists(
            poll_revision,
            search_owner_id == ^owner and
              fragment("ARRAY[?] @> ARRAY[?::bigint]", search_owner_id, ^owner) and ^match
          )
        )
      else
        Ash.Query.filter(
          query,
          exists(poll_revision, search_owner_id == parent(owner_id) and ^match)
        )
      end
    end
  end

  @doc "Applies the same word or positional query to chat notes."
  def note_predicate(search) do
    q = tsquery(search)

    Ash.Expr.expr(
      note != "" and
        fragment(
          "ic_search_lexemes(?) @@ to_tsquery('pg_catalog.simple'::regconfig, ?::text)",
          note,
          ^q
        )
    )
  end

  @doc "Reads canonical source text only for the requested, authorized stored messages."
  def load_texts(messages, actor), do: read_texts(messages, actor, :read)

  defp read_texts(messages, actor, action) do
    messages
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.chunk_every(@text_batch_size)
    |> Enum.reduce(%{}, fn ids, acc ->
      # The message policy and the visible role/owner/trace projection share a
      # SQL snapshot. Never apply this to an inherited, already projected fork.
      projected =
        ChatMessage
        |> Ash.Query.for_read(action, %{}, actor: actor)
        |> Ash.Query.filter(id in ^ids)
        |> Ash.Query.select([:id])
        |> Ash.Query.calculate(
          :canonical_text,
          :string,
          Ash.Expr.expr(
            fragment(
              "(SELECT d.body FROM ic_message_search_documents(ARRAY[?::bigint]) d WHERE d.search_owner = ?)",
              id,
              owner_id
            )
          ),
          %{},
          trim?: false,
          allow_empty?: true
        )
        |> Ash.read!(actor: actor, page: false)

      Enum.reduce(projected, acc, fn record, texts ->
        Map.put(texts, record.id, record.calculations.canonical_text || "")
      end)
    end)
  end

  @doc "Builds snippets only for the already selected messages, from their canonical, authorized text."
  def load_snippets([], _search, _actor), do: %{}
  def load_snippets(_messages, :empty, _actor), do: %{}

  def load_snippets(messages, search, actor) do
    patterns = snippet_patterns(search)

    messages
    |> read_texts(actor, :list_search_window)
    |> Map.new(fn {id, text} -> {id, snippet_window(text, patterns, @snippet_radius)} end)
  end

  defp wanted_trace_item_type(message) do
    case Map.get(message, :role) do
      :user -> [:input, :handoff_request, :handoff_history, :handoff_message]
      :assistant -> [:answer, :handoff_summary]
      _ -> []
    end
  end

  defp trace_item_type_matches?(_item, []), do: false

  defp trace_item_type_matches?(item, wanted_types) when is_list(wanted_types) do
    Map.get(item, :type) in wanted_types
  end

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0

  defp sort_key(record) do
    {sort_seq(record), Map.get(record, :id, 0)}
  end

  @doc "A bounded context window around the earliest prefix hit, preferring the entire ordered sequence."
  def snippet(text, search, radius \\ @snippet_radius)

  def snippet(text, {mode, [_ | _]} = search, radius)
      when is_binary(text) and mode in [:prefixes, :consecutive] and is_integer(radius) and
             radius >= 0 do
    snippet_window(text, snippet_patterns(search), radius)
  end

  def snippet(_text, _search, _radius), do: nil

  # The database parser also recognizes compound lexemes (e.g. hyphenated
  # identifiers). If the display tokenizer differs, prefer a long prefix or
  # finally a leading preview of the already matched/authorized message.
  defp snippet_patterns({mode, terms}) do
    boundary = "(?<!#{@word_chars})"
    anchors = terms |> Enum.filter(&prefix?/1) |> Enum.sort_by(&byte_size/1, :desc)
    alternatives = Enum.map_join(anchors, "|", &Regex.escape/1)
    any_prefix = Regex.compile!(boundary <> "(?:" <> alternatives <> ")", "iu")

    if mode == :consecutive and length(terms) > 1 do
      {earlier, [last]} = Enum.split(terms, -1)

      sequence =
        Enum.map(earlier, fn term ->
          Regex.escape(term) <> if(prefix?(term), do: @word_chars <> "*+", else: "")
        end)

      ending = Regex.escape(last) <> if(prefix?(last), do: "", else: "(?!#{@word_chars})")
      [Regex.compile!(boundary <> Enum.join(sequence ++ [ending], @separator), "iu"), any_prefix]
    else
      [any_prefix]
    end
  end

  defp snippet_window("", _patterns, _radius), do: nil

  defp snippet_window(text, patterns, radius) do
    text = String.normalize(text, :nfc)

    {start, len} =
      Enum.find_value(patterns, {0, 0}, fn pattern ->
        case Regex.run(pattern, text, return: :index, capture: :first) do
          [position] -> position
          nil -> nil
        end
      end)

    before_match = binary_part(text, 0, start)
    rest = binary_part(text, start, byte_size(text) - start)
    before = if radius == 0, do: "", else: String.slice(before_match, -radius, radius)
    match = rest |> binary_part(0, len) |> String.slice(0, @max_snippet_match)
    {context, remaining} = String.split_at(rest, String.length(match) + radius)
    prefix = if byte_size(before) < start, do: "...", else: ""
    suffix = if remaining == "", do: "", else: "..."
    prefix <> before <> context <> suffix
  end

  @doc "Returns text from an already authorized, possibly projected fork trace."
  def from_loaded(message) do
    message.steps
    |> Enum.sort_by(&sort_key/1)
    |> Enum.flat_map(fn step -> Enum.sort_by(step.items, &sort_key/1) end)
    |> Enum.filter(&trace_item_type_matches?(&1, wanted_trace_item_type(message)))
    |> Enum.map(fn item ->
      item.contents
      |> Enum.filter(&(&1.kind == :text))
      |> Enum.sort_by(&sort_key/1)
      |> Enum.map_join("", &to_string(&1.content_text || ""))
    end)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end
end
