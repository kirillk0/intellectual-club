defmodule IntellectualClub.Chat.ForkHistoryRevision do
  @moduledoc """
  Metadata-only revision of an actor's live, anchored linked-fork history.

  This is not a payload hash or a replacement for ForkHistory's validation. A
  caller must capture the revision before loading the prefix and keep that same
  revision even when full tool-call decoding makes the presentation unavailable.
  Every entity query is authorized by Ash as the caller. Only small Chat records
  and one aggregate row per source cross the database boundary.
  """

  use Ash.Resource,
    domain: IntellectualClub.Chat,
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Query
  require Ash.Query
  require Logger

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Files.File
  alias IntellectualClub.Repo

  @max_depth 32
  @max_id 9_223_372_036_854_775_807
  @retry_bucket_seconds 60
  @chat_fields [
    :id,
    :owner_id,
    :parent_chat_id,
    :parent_message_id,
    :parent_tool_call_item_id,
    :fork_source_step_id,
    :fork_task
  ]
  @message_fields [:id, :parent_id, :role]
  @step_fields [:id, :chat_message_id, :sequence, :response_final]
  @item_fields [
    :id,
    :chat_message_step_id,
    :sequence,
    :type,
    :tool_call_item_id,
    :created_at,
    :updated_at
  ]
  @content_fields [
    :id,
    :external_id,
    :chat_message_item_id,
    :sequence,
    :kind,
    :file_id,
    :updated_at
  ]
  @file_fields [:id, :external_id, :filename, :mime_type, :size_bytes]

  # These relations contain only authorized metadata, never application tables.
  # Sorted tuples detect deletions, replacements and reparenting even when both
  # the row count and maximum timestamp stay unchanged. Payloads are not hashed.
  @summary_sql """
  SELECT
    COALESCE((SELECT a.response_final
      AND EXISTS (SELECT 1 FROM revision_branch b
                  WHERE b.id = a.chat_message_id AND b.role = 'assistant')
      AND EXISTS (SELECT 1 FROM revision_branch b WHERE b.parent_id IS NULL)
      AND EXISTS (SELECT 1 FROM revision_call)
      FROM revision_anchor a), FALSE) AS available,
    md5(jsonb_build_array(
      (SELECT md5(COALESCE(string_agg(
        jsonb_build_array(id, parent_id, role)::text, ',' ORDER BY id), ''))
       FROM revision_branch),
      (SELECT md5(COALESCE(string_agg(
        jsonb_build_array(id, chat_message_id, sequence)::text, ',' ORDER BY id), ''))
       FROM revision_steps),
      (SELECT md5(COALESCE(string_agg(
        jsonb_build_array(id, chat_message_step_id, sequence, type, tool_call_item_id,
                         created_at, updated_at)::text, ',' ORDER BY id), ''))
       FROM revision_items),
      (SELECT md5(COALESCE(string_agg(
        jsonb_build_array(id, external_id, chat_message_item_id, sequence, kind,
                         file_id, updated_at)::text, ',' ORDER BY id), ''))
       FROM revision_contents),
      (SELECT md5(COALESCE(string_agg(
        jsonb_build_array(content_id, id, external_id, filename, mime_type,
                         size_bytes)::text, ',' ORDER BY content_id), ''))
       FROM revision_files)
    )::text) AS digest
  """

  actions do
    action :revision, :string do
      public?(false)
      transaction?(false)
      allow_nil?(true)
      argument(:chat_id, :integer, allow_nil?: false)

      run fn input, context ->
        {:ok, compute_revision(input.arguments.chat_id, context.actor)}
      end
    end
  end

  policies do
    policy action_type(:action) do
      authorize_if actor_present()
    end
  end

  @doc """
  Returns nil only for a readable non-linked chat, otherwise an opaque revision.

  Loaded Chat structs are always re-read for current anchors and authorization.
  Missing, unreadable or corrupt sources return a safe unavailable token.
  Unexpected read failures return a retry token that changes once per minute, so
  a transient failure cannot acknowledge stale content indefinitely while a
  persistent failure does not force a full reload on every idle probe. Supplied
  structs and source owners never confer additional authority.
  """
  @spec revision(Chat.t() | integer(), map() | nil) :: binary() | nil
  def revision(%Chat{id: id}, actor), do: revision(id, actor)

  def revision(id, %{id: actor_id} = actor)
      when is_integer(id) and id >= -@max_id - 1 and id <= @max_id and
             is_integer(actor_id) and actor_id >= -@max_id - 1 and actor_id <= @max_id do
    __MODULE__
    |> Ash.ActionInput.for_action(:revision, %{chat_id: id}, actor: actor)
    |> Ash.run_action(actor: actor, authorize?: true)
    |> case do
      {:ok, revision} ->
        revision

      {:error, %Ash.Error.Forbidden{}} ->
        token(:unavailable)

      {:error, reason} ->
        Logger.warning("Linked fork revision for chat #{id} failed: #{describe(reason)}")

        retry_token(id)
    end
  rescue
    Ash.Error.Forbidden ->
      token(:unavailable)

    error ->
      Logger.warning(
        "Linked fork revision for chat #{id} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      retry_token(id)
  end

  def revision(_chat, _actor), do: token(:unavailable)

  defp compute_revision(id, actor) do
    case readable_chat(id, actor) do
      %Chat{} = chat ->
        if linked?(chat) do
          token({actor.id, walk(chat, actor, MapSet.new(), 0)})
        end

      _ ->
        token(:unavailable)
    end
  end

  defp readable_chat(id, actor) when is_integer(id) do
    Chat
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select(@chat_fields)
    |> Ash.read_one!(actor: actor, authorize?: true)
  end

  defp readable_chat(_id, _actor), do: nil

  defp linked?(chat), do: not is_nil(chat.fork_source_step_id) or not is_nil(chat.fork_task)

  defp walk(chat, actor, visited, depth) do
    identity = Enum.map(@chat_fields, &Map.fetch!(chat, &1))

    cond do
      MapSet.member?(visited, chat.id) ->
        {:unavailable, identity}

      not linked?(chat) ->
        {:root, chat.id, chat.owner_id}

      depth >= @max_depth or not valid_link?(chat) ->
        {:unavailable, identity}

      true ->
        case readable_chat(chat.parent_chat_id, actor) do
          %Chat{} = source ->
            summary = source_summary(source.id, chat, actor)

            ancestors =
              if summary.available do
                walk(source, actor, MapSet.put(visited, chat.id), depth + 1)
              else
                :unavailable
              end

            {:linked, identity, source.id, source.owner_id, summary, ancestors}

          _ ->
            {:unavailable, identity}
        end
    end
  end

  defp valid_link?(chat) do
    is_integer(chat.parent_chat_id) and is_integer(chat.parent_message_id) and
      is_integer(chat.parent_tool_call_item_id) and is_integer(chat.fork_source_step_id) and
      is_binary(chat.fork_task)
  end

  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)

  defp retry_token(chat_id),
    do: token({:retry, chat_id, div(System.system_time(:second), @retry_bucket_seconds)})

  defp token(metadata) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({:fork_history_metadata_v1, metadata}, [:deterministic])
      )
      |> Base.encode16(case: :lower)

    "fhr1:" <> digest
  end

  defp authorized(resource, fields, actor) do
    %{query: query} =
      resource
      |> Ash.Query.select(fields)
      |> Ash.data_layer_query!(actor: actor, authorize?: true)

    # Keep Ash's authorization filters/joins, projecting only the requested
    # columns with stable names for the metadata CTEs below.
    query |> exclude(:select) |> select([row], map(row, ^fields))
  end

  defp source_summary(source_id, chat, actor) do
    messages =
      ChatMessage
      |> Ash.Query.filter(chat_id == ^source_id)
      |> authorized(@message_fields, actor)

    # Bind the source on each authorized relation, not only on the final join.
    # Materialize these narrow relations before joining the recursive branch:
    # its small row estimate can otherwise repeat policy joins for every row.
    steps =
      ChatMessageStep
      |> Ash.Query.filter(chat_message.chat_id == ^source_id)
      |> authorized(@step_fields, actor)

    items =
      ChatMessageItem
      |> Ash.Query.filter(chat_message_step.chat_message.chat_id == ^source_id)
      |> authorized(@item_fields, actor)

    contents =
      ChatMessageContent
      |> Ash.Query.filter(chat_message_item.chat_message_step.chat_message.chat_id == ^source_id)
      |> authorized(@content_fields, actor)

    files = authorized(File, @file_fields, actor)

    branch_start =
      from(m in "revision_messages",
        where: m.id == ^chat.parent_message_id,
        select: map(m, ^@message_fields)
      )

    branch_parent =
      from(m in "revision_messages",
        join: child in "revision_branch",
        on: m.id == child.parent_id,
        select: map(m, ^@message_fields)
      )

    # UNION (not UNION ALL) terminates corrupt cycles without returning a path
    # array or one row per history node to BEAM. A branch must reach a nil parent.
    branch = union(branch_start, ^branch_parent)

    anchor =
      from(s in "revision_source_steps",
        where: s.id == ^chat.fork_source_step_id and s.chat_message_id == ^chat.parent_message_id,
        select: map(s, ^@step_fields)
      )

    branch_ids = from(m in "revision_branch", select: m.id)
    step_ids = from(s in "revision_steps", select: s.id)
    item_ids = from(i in "revision_items", select: i.id)

    # IS TRUE keeps membership as a hashable subplan rather than flattening it
    # into a nested-loop join driven by the recursive CTE's low row estimate.
    scoped_steps =
      from(s in "revision_source_steps",
        cross_join: a in "revision_anchor",
        where: fragment("(?) IS TRUE", s.chat_message_id in subquery(branch_ids)),
        where: s.chat_message_id != a.chat_message_id or s.sequence <= a.sequence,
        select: map(s, ^@step_fields)
      )

    source_items =
      from(i in "revision_all_items",
        where: fragment("(?) IS TRUE", i.chat_message_step_id in subquery(step_ids)),
        select: map(i, ^@item_fields)
      )

    scoped_items =
      from(i in "revision_source_items",
        left_join: p in "revision_placements",
        on: p.item_id == i.id,
        where:
          i.chat_message_step_id != ^chat.fork_source_step_id or
            (i.type not in ["tool_result", "artifact", "error"] and
               (i.type != "steering" or p.placement == "before_response")),
        select: map(i, ^@item_fields)
      )

    scoped_contents =
      from(c in "revision_source_contents",
        where: fragment("(?) IS TRUE", c.chat_message_item_id in subquery(item_ids)),
        select: map(c, ^@content_fields)
      )

    scoped_files =
      from(c in "revision_contents",
        left_join: f in subquery(files),
        on: f.id == c.file_id,
        where: c.kind == "media",
        select: %{
          content_id: c.id,
          id: f.id,
          external_id: f.external_id,
          filename: f.filename,
          mime_type: f.mime_type,
          size_bytes: f.size_bytes
        }
      )

    selected_call =
      from(i in "revision_items",
        where:
          i.id == ^chat.parent_tool_call_item_id and
            i.chat_message_step_id == ^chat.fork_source_step_id and i.type == "tool_call",
        select: %{id: i.id}
      )

    from(r in "revision_summary", select: %{available: r.available, digest: r.digest})
    |> recursive_ctes(true)
    # Reuse the authorized metadata once: inlining can make the recursive arm
    # rescan the source chat and repeat its policy joins for every ancestor.
    |> with_cte("revision_messages", as: ^messages, materialized: true)
    |> with_cte("revision_branch", as: ^branch)
    |> with_cte("revision_source_steps", as: ^steps, materialized: true)
    |> with_cte("revision_all_items", as: ^items, materialized: true)
    |> with_cte("revision_source_contents", as: ^contents, materialized: true)
    |> with_cte("revision_anchor", as: ^anchor)
    |> with_cte("revision_steps", as: ^scoped_steps)
    |> with_cte("revision_source_items", as: ^source_items, materialized: false)
    |> with_cte("revision_placements",
      as: ^placements(chat.fork_source_step_id, actor),
      materialized: true
    )
    |> with_cte("revision_items", as: ^scoped_items)
    |> with_cte("revision_contents", as: ^scoped_contents)
    |> with_cte("revision_files", as: ^scoped_files)
    |> with_cte("revision_call", as: ^selected_call)
    |> with_cte("revision_summary", as: fragment(@summary_sql))
    |> Repo.one()
    |> case do
      nil -> %{available: false, digest: nil}
      summary -> summary
    end
  end

  defp placements(step_id, actor) do
    # Only boundary steering needs a JSON scalar. A per-item LIMIT prevents the
    # planner from inspecting/detoasting unrelated contents before the item join.
    boundary_items =
      ChatMessageItem
      |> Ash.Query.filter(chat_message_step_id == ^step_id and type == :steering)
      |> authorized([:id], actor)

    contents =
      ChatMessageContent
      |> authorized([:id, :chat_message_item_id, :sequence, :kind, :content_json], actor)
      |> exclude(:select)

    first_placement =
      from(c in contents,
        where: c.chat_message_item_id == parent_as(:boundary_item).id and c.kind == :opaque,
        where:
          fragment("? ->> 'placement'", c.content_json) in ["before_response", "after_response"],
        order_by: [asc: c.sequence, asc: c.id],
        limit: 1,
        select: %{placement: fragment("? ->> 'placement'", c.content_json)}
      )

    from(i in subquery(boundary_items),
      as: :boundary_item,
      inner_lateral_join: p in subquery(first_placement),
      on: true,
      select: %{item_id: i.id, placement: p.placement}
    )
  end
end
