defmodule IntellectualClub.Chat.ChatDraft do
  @moduledoc """
  Private composer text with optimistic concurrency. Empty rows retain a revision
  so stale devices cannot resurrect a submitted or discarded draft. The conditional
  upsert is encapsulated in an authorized Ash action to protect first-write races.
  """
  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Chat.{Chat, ReadStateEvents}
  alias IntellectualClub.Repo
  require Ash.Query
  require Logger

  @max_revision 9_223_372_036_854_775_806
  @max_bytes 1_048_576

  postgres do
    table "chat_drafts"
    repo(Repo)

    references do
      reference(:chat, on_delete: :delete)
      reference(:user, on_delete: :delete)
    end

    custom_indexes do
      index([:user_id, :updated_at], where: "text <> ''")
    end
  end

  attributes do
    attribute :chat_id, :integer, primary_key?: true, allow_nil?: false
    attribute :user_id, :integer, primary_key?: true, allow_nil?: false

    attribute :text, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]

    attribute :revision, :integer, allow_nil?: false, default: 0
    attribute :updated_at, :utc_datetime_usec, allow_nil?: false
  end

  relationships do
    belongs_to :chat, Chat, define_attribute?: false, attribute_type: :integer, allow_nil?: false

    belongs_to :user, IntellectualClub.Accounts.User,
      define_attribute?: false,
      attribute_type: :integer,
      allow_nil?: false
  end

  actions do
    defaults [:read]

    action :save, :map do
      argument :chat_id, :integer, allow_nil?: false
      argument :params, :map, allow_nil?: false

      run fn input, context ->
        save_authorized(input.arguments.chat_id, input.arguments.params, context.actor)
      end
    end

    action :consume, :boolean do
      argument :chat_id, :integer, allow_nil?: false
      argument :text, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]
      argument :revision, :integer, allow_nil?: false

      run fn input, context ->
        with :ok <- owned_chat(input.arguments.chat_id, context.actor) do
          result =
            Repo.query!(
              """
              UPDATE chat_drafts SET text = '', revision = revision + 1, updated_at = $5
              WHERE chat_id = $1 AND user_id = $2 AND revision = $3 AND text = $4 AND text <> ''
              """,
              [
                input.arguments.chat_id,
                context.actor.id,
                input.arguments.revision,
                input.arguments.text,
                DateTime.utc_now()
              ]
            )

          {:ok, result.num_rows > 0}
        end
      end
    end
  end

  policies do
    policy action_type(:read) do
      forbid_unless expr(user_id == ^actor(:id))
      authorize_if expr(chat.owner_id == ^actor(:id))
    end

    policy action([:save, :consume]) do
      authorize_if actor_present()
    end
  end

  def get(chat_id, actor) do
    with :ok <- owned_chat(chat_id, actor) do
      draft = __MODULE__ |> Ash.Query.filter(chat_id == ^chat_id) |> Ash.read_one!(actor: actor)
      {:ok, payload(draft, chat_id)}
    end
  end

  def save(chat_id, params, actor) do
    result =
      __MODULE__
      |> Ash.ActionInput.for_action(:save, %{chat_id: chat_id, params: params}, actor: actor)
      |> Ash.run_action(actor: actor, authorize?: true)

    case result do
      {:ok, %{conflict: false, draft: draft}} -> publish(actor.id, chat_id, draft.revision)
      _ -> :ok
    end

    result
  end

  @doc "Consumes only an acknowledged snapshot, inside the caller's acceptance transaction."
  def consume(chat_id, text, revision, actor)
      when is_integer(revision) and revision >= 0 and revision <= @max_revision and
             is_binary(text) do
    __MODULE__
    |> Ash.ActionInput.for_action(:consume, %{chat_id: chat_id, text: text, revision: revision},
      actor: actor
    )
    |> Ash.run_action!(actor: actor, authorize?: true)
  end

  def consume(_chat_id, _text, _revision, _actor), do: false

  @doc "Publishes after the acceptance transaction has committed."
  def publish_current(chat_id, actor) do
    case get(chat_id, actor) do
      {:ok, draft} -> publish(actor.id, chat_id, draft.revision)
      _ -> :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Could not publish accepted chat draft invalidation: #{Exception.message(exception)}"
      )

      :ok
  end

  def load_many([], _actor), do: %{}

  def load_many(chats, actor) do
    ids = Enum.map(chats, & &1.id)

    __MODULE__
    |> Ash.Query.filter(chat_id in ^ids and text != "")
    |> Ash.Query.select([:chat_id, :updated_at])
    |> Ash.read!(actor: actor)
    |> Map.new(
      &{&1.chat_id, %{has_draft: true, draft_updated_at: DateTime.to_iso8601(&1.updated_at)}}
    )
  end

  def list_marker(actor) do
    Ash.aggregate!(__MODULE__, [{:row_count, :count}, {:revision_sum, :sum, field: :revision}],
      actor: actor
    )
  end

  defp owned_chat(chat_id, actor) do
    case Chat
         |> Ash.Query.filter(id == ^chat_id and owner_id == ^actor.id)
         |> Ash.read_one(actor: actor, authorize?: true) do
      {:ok, %Chat{}} -> :ok
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp save_authorized(chat_id, params, actor) do
    text = params["text"]
    revision = params["expected_revision"]

    with :ok <- owned_chat(chat_id, actor) do
      cond do
        not is_binary(text) or byte_size(text) > @max_bytes ->
          {:ok, %{error: "text must be a string of at most 1 MiB"}}

        not is_integer(revision) or revision < 0 or revision > @max_revision ->
          {:ok, %{error: "expected_revision must be a nonnegative integer"}}

        true ->
          result =
            Repo.query!(
              """
              INSERT INTO chat_drafts AS d (chat_id, user_id, text, revision, updated_at)
              SELECT $1, $2, $3, 1, $5
              WHERE $4::bigint = 0 OR EXISTS (SELECT 1 FROM chat_drafts WHERE chat_id = $1 AND user_id = $2)
              ON CONFLICT (chat_id, user_id) DO UPDATE
              SET text = EXCLUDED.text, revision = d.revision + 1, updated_at = EXCLUDED.updated_at
              WHERE d.revision = $4
              RETURNING text, revision, updated_at
              """,
              [chat_id, actor.id, text, revision, DateTime.utc_now()]
            )

          case result.rows do
            [[saved_text, saved_revision, updated_at]] ->
              {:ok,
               %{
                 conflict: false,
                 draft: %{
                   chat_id: chat_id,
                   text: saved_text,
                   revision: saved_revision,
                   updated_at: timestamp(updated_at)
                 }
               }}

            [] ->
              with {:ok, draft} <- get(chat_id, actor), do: {:ok, %{conflict: true, draft: draft}}
          end
      end
    else
      {:error, :not_found} -> {:ok, %{error: :not_found}}
      {:error, error} -> {:error, error}
    end
  end

  defp payload(nil, chat_id), do: %{chat_id: chat_id, text: "", revision: 0, updated_at: nil}

  defp payload(draft, chat_id),
    do: %{
      chat_id: chat_id,
      text: draft.text,
      revision: draft.revision,
      updated_at: timestamp(draft.updated_at)
    }

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp timestamp(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp publish(user_id, chat_id, revision) do
    Phoenix.PubSub.broadcast(
      IntellectualClub.PubSub,
      ReadStateEvents.topic(user_id),
      {:chat_draft_changed, chat_id, revision}
    )
  end
end
