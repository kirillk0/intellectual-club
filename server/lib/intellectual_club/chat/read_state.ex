defmodule IntellectualClub.Chat.ReadState do
  @moduledoc """
  Durable personal read state. CAS is performed in one SQL upsert inside this
  Ash action, after an authorized chat read. Personal writes never update chat, message, or activity rows.
  A personal write takes a chat key-share lock before its upsert, serializing with bulk archive. Missing rows have version/revisions zero.
  """
  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Chat.{Chat, ChatActivity}
  alias IntellectualClub.Repo
  require Ash.Query

  postgres do
    table("chat_read_states")
    repo(Repo)

    references do
      reference(:chat, on_delete: :delete)
      reference(:user, on_delete: :delete)
    end
  end

  attributes do
    attribute :chat_id, :integer, primary_key?: true, allow_nil?: false
    attribute :user_id, :integer, primary_key?: true, allow_nil?: false
    attribute :read_revision, :integer, allow_nil?: false, default: 0
    attribute :manual_unread, :boolean, allow_nil?: false, default: false
    attribute :snoozed_until, :utc_datetime_usec
    attribute :state_version, :integer, allow_nil?: false, default: 0
    attribute :archived_revision, :integer
  end

  relationships do
    belongs_to :chat, Chat, define_attribute?: false, attribute_type: :integer, allow_nil?: false

    belongs_to :user, IntellectualClub.Accounts.User,
      define_attribute?: false,
      attribute_type: :integer,
      allow_nil?: false
  end

  actions do
    defaults([:read])

    action :mutate, :map do
      transaction? true
      argument :chat_id, :integer, allow_nil?: false
      argument :params, :map, allow_nil?: false

      run fn input, context ->
        mutate_authorized(input.arguments.chat_id, input.arguments.params, context.actor)
      end
    end

    action :archive_other, :map do
      argument :bot_filter, :term
      argument :expected_revision, :string, allow_nil?: false

      run fn input, context ->
        archive_other_authorized(
          context.actor,
          input.arguments.bot_filter,
          input.arguments.expected_revision
        )
      end
    end
  end

  policies do
    policy action_type(:read) do
      forbid_unless expr(user_id == ^actor(:id))
      authorize_if expr(chat.owner_id == ^actor(:id))
      authorize_if expr(chat.shared_incoming == true)
    end

    policy action([:mutate, :archive_other]) do
      authorize_if actor_present()
    end
  end

  def mutate(chat_id, params, actor) do
    __MODULE__
    |> Ash.ActionInput.for_action(:mutate, %{chat_id: chat_id, params: params}, actor: actor)
    |> Ash.run_action(actor: actor, authorize?: true)
  end

  def archive_other(actor, bot_filter, expected_revision) do
    __MODULE__
    |> Ash.ActionInput.for_action(
      :archive_other,
      %{bot_filter: bot_filter, expected_revision: expected_revision},
      actor: actor
    )
    |> Ash.run_action(actor: actor, authorize?: true)
  end

  defp archive_other_authorized(actor, bot_filter, expected_revision) do
    result =
      Repo.transaction(fn ->
        # Chat locks also protect absent personal rows through their foreign keys.
        # Existing draft/state rows are locked before taking the confirmation snapshot.
        Chat
        |> Ash.Query.filter(owner_id == ^actor.id)
        |> Ash.Query.select([:id])
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.lock("FOR UPDATE")
        |> Ash.read!(actor: actor, page: false)

        for resource <- [IntellectualClub.Chat.ChatDraft, __MODULE__] do
          resource
          |> Ash.Query.filter(user_id == ^actor.id)
          |> Ash.Query.sort(chat_id: :asc)
          |> Ash.Query.lock("FOR UPDATE")
          |> Ash.read!(actor: actor, page: false)
        end

        snapshot = IntellectualClub.Chat.Archive.snapshot(actor, bot_filter)
        if snapshot.revision != expected_revision, do: Repo.rollback(:conflict)
        rows = snapshot.rows

        if rows != [] do
          result =
            Repo.query!(
              """
              INSERT INTO chat_read_states AS s
                (chat_id, user_id, read_revision, manual_unread, state_version, archived_revision)
              SELECT id, $1, 0, FALSE, 1, activity
              FROM unnest($2::bigint[], $3::bigint[], $4::bigint[]) AS input(id, version, activity)
              ON CONFLICT (chat_id, user_id) DO UPDATE SET
                archived_revision = EXCLUDED.archived_revision, state_version = s.state_version + 1
              WHERE s.state_version = (SELECT version FROM unnest($2::bigint[], $3::bigint[]) AS expected(id, version) WHERE id = s.chat_id)
              RETURNING chat_id
              """,
              [
                actor.id,
                Enum.map(rows, &elem(&1, 0)),
                Enum.map(rows, &elem(&1, 1)),
                Enum.map(rows, &elem(&1, 2))
              ]
            )

          if result.num_rows != length(rows), do: Repo.rollback(:conflict)
        end

        %{count: length(rows), chat_ids: Enum.map(rows, &elem(&1, 0))}
      end)

    case result do
      {:ok, result} ->
        for id <- result.chat_ids, do: IntellectualClub.Chat.ReadStateEvents.publish(actor.id, id)
        {:ok, Map.delete(result, :chat_ids)}

      {:error, :conflict} ->
        {:ok, %{conflict: true}}

      {:error, error} ->
        {:error, error}
    end
  end

  def load_many([], _actor), do: %{}

  def load_many(chats, actor) do
    ids = Enum.map(chats, & &1.id)
    states = __MODULE__ |> Ash.Query.filter(chat_id in ^ids) |> Ash.read!(actor: actor)
    activities = ChatActivity |> Ash.Query.filter(chat_id in ^ids) |> Ash.read!(actor: actor)
    states = Map.new(states, &{&1.chat_id, &1})
    activities = Map.new(activities, &{&1.chat_id, &1.revision})
    now = DateTime.utc_now()
    Map.new(ids, &{&1, payload(Map.get(states, &1, %{}), Map.get(activities, &1, 0), now)})
  end

  def list_marker(actor, now \\ DateTime.utc_now()) do
    future = Ash.Query.filter(__MODULE__, snoozed_until > ^now).filter

    marker =
      Ash.aggregate!(
        __MODULE__,
        [
          {:row_count, :count},
          {:version_sum, :sum, field: :state_version},
          {:snoozed_count, :count, query: [filter: future]},
          {:next_expiry, :min, field: :snoozed_until, query: [filter: future]}
        ],
        actor: actor
      )

    %{
      rows: Map.drop(marker, [:next_expiry]),
      next_expiry: if(marker.next_expiry, do: DateTime.to_iso8601(marker.next_expiry))
    }
  end

  def next_expiry(states) do
    states
    |> Enum.filter(&(is_map(&1) and Map.get(&1, :is_snoozed) == true))
    |> Enum.map(& &1.snoozed_until)
    |> Enum.min_by(
      fn iso ->
        {:ok, date, _} = DateTime.from_iso8601(iso)
        DateTime.to_unix(date, :microsecond)
      end,
      fn -> nil end
    )
  end

  def payload(state, activity, now \\ DateTime.utc_now()) do
    read = Map.get(state, :read_revision, 0)
    manual = Map.get(state, :manual_unread, false)
    snooze = Map.get(state, :snoozed_until)
    snoozed = not is_nil(snooze) and DateTime.compare(snooze, now) == :gt
    unread = manual or activity > read

    %{
      activity_revision: activity,
      read_revision: read,
      manual_unread: manual,
      snoozed_until: if(snooze, do: DateTime.to_iso8601(snooze)),
      state_version: Map.get(state, :state_version, 0),
      is_archived:
        not is_nil(Map.get(state, :archived_revision)) and
          activity <= Map.get(state, :archived_revision),
      has_unread: unread,
      is_unread: unread and not snoozed,
      is_snoozed: snoozed
    }
  end

  defp mutate_authorized(id, params, actor) do
    chat =
      Chat
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.lock("FOR KEY SHARE")
      |> Ash.read_one!(actor: actor, authorize?: true)

    if is_nil(chat) do
      {:ok, %{error: :not_found}}
    else
      if chat.subagent and params["action"] in ["archive", "unarchive"] do
        {:ok, %{error: "Archive the parent chat instead"}}
      else
        mutate_chat(chat, params, actor)
      end
    end
  end

  defp mutate_chat(chat, params, actor) do
    id = chat.id
    current = load_many([chat], actor)[id]

    case validate(params, current.activity_revision) do
      {:ok, action, version, observed, explicit, snooze} ->
        # A single conditional upsert also protects the absent-row/version-zero race.
        result =
          Repo.query!(
            """
            INSERT INTO chat_read_states AS s
              (chat_id, user_id, read_revision, manual_unread, snoozed_until, state_version, archived_revision)
            SELECT $1, $2, CASE WHEN $3 = 'read' THEN $5::bigint ELSE 0 END,
              $3 IN ('unread', 'snooze'), CASE WHEN $3 = 'snooze' THEN $7::timestamp ELSE NULL END, 1,
              CASE WHEN $3 = 'archive' THEN $5::bigint ELSE NULL END
            WHERE $4::bigint = 0 OR EXISTS (SELECT 1 FROM chat_read_states WHERE chat_id=$1 AND user_id=$2)
            ON CONFLICT (chat_id, user_id) DO UPDATE SET
              read_revision = CASE WHEN $3 = 'read' THEN GREATEST(s.read_revision, $5) ELSE s.read_revision END,
              manual_unread = CASE WHEN $3 IN ('unread','snooze') THEN TRUE
                WHEN $3 = 'read' AND $6 THEN FALSE ELSE s.manual_unread END,
              snoozed_until = CASE WHEN $3 = 'snooze' THEN $7::timestamp
                WHEN $3 IN ('unread','unsnooze') OR ($3 = 'read' AND $6) THEN NULL ELSE s.snoozed_until END,
              state_version = s.state_version + 1,
              archived_revision = CASE WHEN $3 = 'archive' THEN $5::bigint
                WHEN $3 = 'unarchive' THEN NULL ELSE s.archived_revision END
            WHERE s.state_version = $4
            RETURNING state_version
            """,
            [id, actor.id, action, version, observed, explicit, snooze]
          )

        state = load_many([chat], actor)[id]
        {:ok, %{read_state: state, conflict: result.num_rows == 0}}

      {:error, reason} ->
        {:ok, %{error: reason}}
    end
  end

  defp validate(params, activity) do
    action = params["action"]
    version = params["expected_state_version"]
    observed = params["observed_revision"]
    explicit = Map.get(params, "explicit", false)
    snooze = parse_datetime(params["snoozed_until"])

    cond do
      action not in ["read", "unread", "snooze", "unsnooze", "archive", "unarchive"] ->
        {:error, "Invalid action"}

      not is_integer(version) or version < 0 or version > 9_223_372_036_854_775_806 ->
        {:error, "expected_state_version must be a nonnegative integer"}

      not is_boolean(explicit) ->
        {:error, "explicit must be a boolean"}

      action in ["read", "archive"] and
          (not is_integer(observed) or observed < 0 or observed > activity) ->
        {:error, "observed_revision must be between zero and current activity_revision"}

      action == "snooze" and
          (is_nil(snooze) or DateTime.compare(snooze, DateTime.utc_now()) != :gt) ->
        {:error, "snoozed_until must be a future ISO8601 timestamp"}

      true ->
        {:ok, action, version, if(action in ["read", "archive"], do: observed, else: 0), explicit,
         snooze}
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil
end
