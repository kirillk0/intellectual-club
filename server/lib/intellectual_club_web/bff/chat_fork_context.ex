defmodule IntellectualClubWeb.Bff.ChatForkContext do
  @moduledoc """
  Read-only presentation of the live linked-fork prefix.

  Only the projected tree is serialized: reloading source message steps would
  cross the fork boundary. Source access is checked independently of child access.
  """

  alias IntellectualClub.Chat.ForkHistory
  alias IntellectualClub.Chat.ForkHistoryRevision
  alias IntellectualClubWeb.Bff.ChatAccess
  alias IntellectualClubWeb.Bff.Serializer

  require Logger

  @retry_bucket_seconds 60
  @display_types ~w(input answer reasoning tool_call tool_result steering artifact handoff_request handoff_context handoff_history handoff_message handoff_summary)

  def linked?(chat), do: not is_nil(Map.get(chat, :fork_task))

  def build(chat, actor, opts \\ []) do
    if linked?(chat) do
      # Read the token first: a concurrent source edit must not leave an old
      # presentation paired with a newer revision that suppresses the next refresh.
      build_context(chat, actor, opts, revision(chat, actor))
    end
  end

  @doc "Computes the inherited idle token without building or serializing history."
  def revision(chat, actor) do
    if linked?(chat), do: ForkHistoryRevision.revision(chat, actor)
  end

  defp build_context(chat, actor, opts, revision) do
    with {:ok, sources} <- readable_sources(chat, actor, %{}, 0),
         {:ok, messages} <- ForkHistory.prefix(chat, actor),
         true <- is_list(messages),
         true <- Enum.all?(messages, &known_source?(&1, sources)) do
      context("available", serialize_messages(messages, sources, actor, opts), revision)
    else
      {:error, reason} when is_struct(reason) ->
        Logger.warning(
          "Linked fork context for chat #{chat.id} failed to load: #{describe(reason)}"
        )

        retry_context(revision)

      _other ->
        context("unavailable", [], revision)
    end
  rescue
    # A transient payload/read failure must not acknowledge a healthy metadata
    # token forever, but a persistent failure must not force a full reload on
    # every idle probe either: the retry token changes once per bucket.
    error ->
      Logger.warning(
        "Linked fork context for chat #{chat.id} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      retry_context(revision)
  end

  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)

  defp retry_context(revision) do
    bucket = div(System.system_time(:second), @retry_bucket_seconds)
    context("unavailable", [], digest({:fork_context_retry, revision, bucket}))
  end

  def combine_revision(revision, nil), do: revision

  def combine_revision(revision, inherited) when is_binary(inherited),
    do: digest({revision, inherited})

  def combine_revision(revision, context), do: combine_revision(revision, context.revision)

  defp context(status, messages, revision) do
    %{
      status: status,
      live: true,
      read_only: true,
      revision: revision,
      messages: messages
    }
  end

  defp digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value))
    |> Base.url_encode64(padding: false)
  end

  defp readable_sources(_chat, _actor, _sources, hops) when hops >= 100,
    do: {:error, :lineage_limit}

  defp readable_sources(chat, actor, sources, hops) do
    if Map.has_key?(sources, chat.id) do
      {:error, :lineage_cycle}
    else
      sources = Map.put(sources, chat.id, chat)

      if linked?(chat) do
        with parent_id when is_integer(parent_id) <- Map.get(chat, :parent_chat_id),
             {:ok, parent} <- ChatAccess.fetch_readable_chat(parent_id, actor) do
          readable_sources(parent, actor, sources, hops + 1)
        else
          {:error, _reason} = error -> error
          _other -> {:error, :source_unavailable}
        end
      else
        {:ok, sources}
      end
    end
  end

  defp source_ids(message) do
    metadata = Map.get(message, :fork_inherited)
    metadata = if is_map(metadata), do: metadata, else: %{}

    {
      Map.get(metadata, :source_chat_id) || Map.get(message, :chat_id),
      Map.get(metadata, :source_message_id) || Map.get(message, :id)
    }
  end

  defp known_source?(message, sources) do
    {chat_id, _message_id} = source_ids(message)
    is_nil(chat_id) or Map.has_key?(sources, chat_id)
  end

  @doc "Serializes already projected, loaded trees without any source-step queries."
  def serialize_messages(messages, sources, actor, opts \\ []) do
    Enum.with_index(messages, fn message, index ->
      {chat_id, message_id} = source_ids(message)
      source = Map.get(sources, chat_id)
      message_id = if is_integer(message_id), do: message_id
      source_owned? = is_map(source) and Map.get(source, :owner_id) == Map.get(actor, :id)
      links? = Keyword.get(opts, :links?, true)

      %{
        key: "inherited-#{index}",
        role: string(Map.get(message, :role)),
        source_chat_id: if(is_integer(chat_id), do: chat_id),
        source_message_id: message_id,
        source_url: if(links? and source_owned?, do: "/chats/#{chat_id}"),
        content:
          message
          |> Map.get(:steps)
          |> ordered()
          |> Enum.flat_map(fn step ->
            step
            |> Map.get(:items)
            |> ordered()
            |> Enum.flat_map(&display_item(&1, step, message_id, links? and is_map(source)))
          end)
      }
    end)
  end

  defp display_item(item, step, message_id, links?) do
    type = string(Map.get(item, :type))
    contents = ordered(Map.get(item, :contents))

    if type in @display_types do
      parts =
        Enum.flat_map(contents, fn content ->
          case {string(Map.get(content, :kind)), type} do
            {"text", _} ->
              [%{text: string(Map.get(content, :content_text))}]

            {"json", "tool_call"} ->
              case Jason.encode(Map.get(content, :content_json), pretty: true) do
                {:ok, text} -> [%{text: text}]
                _other -> []
              end

            _other ->
              []
          end
        end)

      attachments =
        contents
        |> Enum.filter(&(string(Map.get(&1, :kind)) == "media"))
        |> Enum.map(&attachment(&1, message_id, links?))

      if parts == [] and attachments == [] do
        []
      else
        [
          %{
            type: type,
            step_sequence: Map.get(step, :sequence) || 0,
            item_sequence: Map.get(item, :sequence) || 0,
            created_at: Serializer.datetime_iso(Map.get(item, :created_at)),
            parts: parts,
            attachments: attachments
          }
        ]
      end
    else
      []
    end
  end

  defp attachment(content, message_id, links?) do
    file = Map.get(content, :file)
    file = if is_map(file) and not is_struct(file, Ash.NotLoaded), do: file, else: %{}
    content_id = Map.get(content, :id)

    available? =
      links? and is_integer(message_id) and is_integer(content_id) and
        is_integer(Map.get(file, :id))

    %{
      name: Map.get(file, :filename) || "file",
      mime_type: Map.get(file, :mime_type) || "application/octet-stream",
      size_bytes: Map.get(file, :size_bytes) || 0,
      kind: "media",
      enabled: available?,
      url:
        if(available?,
          do: "/api/bff/chat-messages/#{message_id}/contents/#{content_id}/file"
        )
    }
  end

  defp ordered(values) when is_list(values),
    do: Enum.sort_by(values, &{Map.get(&1, :sequence) || 0, Map.get(&1, :id) || 0})

  defp ordered(_values), do: []
  defp string(value) when is_atom(value) or is_binary(value), do: to_string(value)
  defp string(_value), do: ""
end
