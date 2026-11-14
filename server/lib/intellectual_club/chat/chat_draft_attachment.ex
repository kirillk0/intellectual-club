defmodule IntellectualClub.Chat.ChatDraftAttachment do
  @moduledoc """
  Private durable draft attachments. Each attachment has an independent revision;
  deleted rows are tombstones so late uploads cannot resurrect removed files.
  """
  use IntellectualClub.Resource,
    domain: IntellectualClub.Chat,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Chat.{Chat, ChatDraft, Uploads, UploadPolicy}
  alias IntellectualClub.Files
  alias IntellectualClub.Files.Changes.DeleteAssociatedFile
  require Ash.Query

  postgres do
    table "chat_draft_attachments"
    repo(IntellectualClub.Repo)

    references do
      reference(:chat, on_delete: :delete)
      reference(:user, on_delete: :delete)
    end

    custom_indexes do
      index([:chat_id, :user_id])
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :ready, :deleted]]

    attribute :revision, :integer, allow_nil?: false, default: 0
    attribute :keep_original, :boolean, allow_nil?: false, default: false
    attribute :metadata, :map, allow_nil?: false, default: %{}
    create_timestamp :created_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :chat, Chat, allow_nil?: false, attribute_type: :integer
    belongs_to :user, IntellectualClub.Accounts.User, allow_nil?: false, attribute_type: :integer
    belongs_to :original_file, IntellectualClub.Files.File, attribute_type: :integer
    belongs_to :compressed_file, IntellectualClub.Files.File, attribute_type: :integer
  end

  actions do
    defaults [:read]

    create :create do
      accept [:id, :chat_id, :status, :metadata]
      change relate_actor(:user)

      change {IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor,
              relationships: [:chat], access: :writable}
    end

    update :update do
      require_atomic? false

      accept [
        :status,
        :revision,
        :keep_original,
        :metadata,
        :original_file_id,
        :compressed_file_id
      ]
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      change {DeleteAssociatedFile, field: :original_file_id, strict?: true}
      change {DeleteAssociatedFile, field: :compressed_file_id, strict?: true}
    end

    action :mutate, :map do
      transaction? true
      argument :chat_id, :integer, allow_nil?: false
      argument :id, :uuid, allow_nil?: false

      argument :operation, :atom,
        allow_nil?: false,
        constraints: [one_of: [:start, :finish, :select, :delete]]

      argument :params, :map, default: %{}

      run fn input, context ->
        args = input.arguments

        result =
          with :ok <- lock_chat(args.chat_id, context.actor) do
            mutate_locked(args.chat_id, args.id, args.operation, args.params, context.actor)
          end

        case result do
          {:error, reason} when is_binary(reason) or reason == :not_found ->
            {:ok, %{error: reason}}

          other ->
            other
        end
      end
    end
  end

  policies do
    policy action_type(:read) do
      forbid_unless expr(user_id == ^actor(:id))
      authorize_if expr(chat.owner_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      forbid_unless expr(user_id == ^actor(:id))
      authorize_if expr(chat.owner_id == ^actor(:id))
    end

    policy action(:mutate) do
      authorize_if actor_present()
    end
  end

  def list(chat_id, actor) do
    with {:ok, _} <- owned_chat(chat_id, actor) do
      {:ok,
       __MODULE__
       |> Ash.Query.filter(chat_id == ^chat_id and status != :deleted)
       |> Ash.Query.sort(created_at: :asc, id: :asc)
       |> Ash.read!(actor: actor, load: [:original_file, :compressed_file])
       |> Enum.map(&payload/1)}
    end
  end

  def mutate(chat_id, id, operation, params, actor) do
    result =
      __MODULE__
      |> Ash.ActionInput.for_action(
        :mutate,
        %{chat_id: chat_id, id: id, operation: operation, params: params},
        actor: actor
      )
      |> Ash.run_action(actor: actor)

    case result do
      {:ok, %{attachment: attachment}} ->
        if operation == :finish and attachment.status == :ready do
          for id <- [params["original_upload_id"], params["compressed_upload_id"]],
              is_binary(id) do
            Uploads.abort_upload(chat_id, id, actor)
          end
        end

        ChatDraft.publish_current(chat_id, actor)

      _ ->
        :ok
    end

    case result do
      {:ok, %{error: reason}} -> {:error, reason}
      other -> other
    end
  end

  def load_file(chat_id, id, variant, actor) when variant in ["original", "compressed"] do
    with {:ok, _} <- owned_chat(chat_id, actor),
         %__MODULE__{status: :ready} = attachment <- find(chat_id, id, actor),
         file_id when is_integer(file_id) <-
           if(variant == "original",
             do: attachment.original_file_id,
             else: attachment.compressed_file_id
           ) do
      Files.load_path(file_id)
    else
      _ -> {:error, :not_found}
    end
  end

  def load_file(_, _, _, _), do: {:error, :not_found}

  @doc "Copies logical file records for a submitted snapshot without copying payload bytes."
  def copy_files(chat_id, specs, policy, actor) do
    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, ids} ->
      with {:ok, attachment} <- matching(chat_id, spec, actor),
           {:ok, file} <- Ash.get(Files.File, selected_file_id(attachment), authorize?: false),
           :ok <-
             UploadPolicy.validate_file_spec(
               file.filename,
               file.mime_type,
               file.size_bytes,
               policy
             ),
           {:ok, copied} <- Files.duplicate_file(file.id) do
        {:cont, {:ok, ids ++ [copied.id]}}
      else
        error ->
          Enum.each(ids, &Files.delete_file_and_maybe_payload/1)
          {:halt, error}
      end
    end)
  end

  @doc "Consumes only exact attachment snapshots inside the message acceptance transaction."
  def consume(chat_id, specs, actor) do
    # The caller already holds the chat lock, which serializes all attachment mutations.
    Enum.each(specs, fn spec ->
      case matching(chat_id, spec, actor) do
        {:ok, attachment} -> delete_files(attachment, actor)
        {:error, reason} -> raise ArgumentError, reason
      end
    end)

    if specs != [], do: touch_draft(chat_id, actor)
    :ok
  end

  defp matching(chat_id, %{"id" => id, "revision" => revision}, actor) do
    case find(chat_id, id, actor) do
      %__MODULE__{status: :ready, revision: ^revision} = attachment -> {:ok, attachment}
      _ -> {:error, "Draft attachment changed or is no longer available. Refresh and try again."}
    end
  end

  defp selected_file_id(%{keep_original: false, compressed_file_id: id}) when is_integer(id),
    do: id

  defp selected_file_id(attachment), do: attachment.original_file_id

  defp owned_chat(chat_id, actor, lock? \\ false) do
    query = Chat |> Ash.Query.filter(id == ^chat_id and owner_id == ^actor.id)
    query = if lock?, do: Ash.Query.lock(query, "FOR UPDATE"), else: query

    case Ash.read_one(query, actor: actor) do
      {:ok, %Chat{} = chat} -> {:ok, chat}
      _ -> {:error, :not_found}
    end
  end

  defp lock_chat(chat_id, actor) do
    with {:ok, _} <- owned_chat(chat_id, actor, true), do: :ok
  end

  defp find(chat_id, id, actor) do
    __MODULE__
    |> Ash.Query.filter(chat_id == ^chat_id and id == ^id)
    |> Ash.read_one!(actor: actor)
  end

  defp mutate_locked(chat_id, id, operation, params, actor) do
    existing = find(chat_id, id, actor)

    case apply_operation(existing, chat_id, id, operation, params, actor) do
      {:ok, attachment} ->
        touch_draft(chat_id, actor)

        {:ok,
         %{
           attachment:
             attachment
             |> Ash.load!([:original_file, :compressed_file], actor: actor)
             |> payload()
         }}

      other ->
        other
    end
  end

  defp apply_operation(nil, chat_id, id, operation, params, actor)
       when operation in [:start, :delete] do
    metadata = Map.take(params, ["filename", "mime_type", "size_bytes"])

    if byte_size(Jason.encode!(metadata)) > 4096 do
      {:error, "Invalid attachment metadata."}
    else
      __MODULE__
      |> Ash.Changeset.for_create(
        :create,
        %{
          id: id,
          chat_id: chat_id,
          metadata: metadata,
          status: if(operation == :delete, do: :deleted, else: :pending)
        },
        actor: actor
      )
      |> Ash.create(actor: actor)
    end
  end

  defp apply_operation(nil, _, _, _, _, _), do: {:error, :not_found}
  defp apply_operation(%{status: :deleted} = attachment, _, _, _, _, _), do: {:ok, attachment}
  defp apply_operation(attachment, _, _, :start, _, _), do: {:ok, attachment}

  defp apply_operation(attachment, _, _, :delete, _, actor),
    do: {:ok, delete_files(attachment, actor)}

  defp apply_operation(%{status: :ready} = attachment, _, _, :finish, _, _), do: {:ok, attachment}

  defp apply_operation(attachment, chat_id, _, :finish, params, actor) do
    ids = [params["original_upload_id"], params["compressed_upload_id"]] |> Enum.reject(&is_nil/1)

    with true <- is_binary(params["original_upload_id"]),
         true <- length(Enum.uniq(ids)) == length(ids),
         {:ok, materialized} <- Uploads.materialize_uploads(chat_id, ids, actor) do
      [original | compressed] = materialized.files

      metadata =
        Map.take(params["image"] || %{}, [
          "width",
          "height",
          "compressed_width",
          "compressed_height",
          "original_embeddable",
          "failed"
        ])

      if byte_size(Jason.encode!(metadata)) > 4096,
        do: raise(ArgumentError, "Invalid image metadata.")

      attachment =
        update!(
          attachment,
          %{
            original_file_id: original.id,
            compressed_file_id:
              case List.first(compressed) do
                nil -> nil
                file -> file.id
              end,
            status: :ready,
            keep_original: params["keep_original"] == true,
            metadata: metadata
          },
          actor
        )

      # Staging cleanup happens after the outer action commits (see mutate/5).
      {:ok, attachment}
    else
      false -> {:error, "Invalid attachment uploads."}
      error -> error
    end
  end

  defp apply_operation(attachment, _, _, :select, params, actor) do
    cond do
      attachment.revision != params["expected_revision"] ->
        {:ok, attachment}

      attachment.status != :ready or not is_boolean(params["keep_original"]) ->
        {:error, "Attachment is not ready."}

      true ->
        {:ok, update!(attachment, %{keep_original: params["keep_original"]}, actor)}
    end
  end

  defp update!(attachment, attrs, actor) do
    attachment
    |> Ash.Changeset.for_update(:update, Map.put(attrs, :revision, attachment.revision + 1),
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  defp delete_files(attachment, actor) do
    updated =
      update!(
        attachment,
        %{status: :deleted, original_file_id: nil, compressed_file_id: nil},
        actor
      )

    for id <- [attachment.original_file_id, attachment.compressed_file_id], is_integer(id) do
      :ok = Files.delete_file_and_maybe_payload(id)
    end

    updated
  end

  defp touch_draft(chat_id, actor) do
    count =
      __MODULE__
      |> Ash.Query.filter(chat_id == ^chat_id and status != :deleted)
      |> Ash.count!(actor: actor)

    ChatDraft.touch_attachments(chat_id, count, actor)
  end

  defp payload(attachment) do
    %{
      id: attachment.id,
      status: attachment.status,
      revision: attachment.revision,
      keep_original: attachment.keep_original,
      metadata: attachment.metadata,
      original: file_payload(attachment.original_file, attachment, "original"),
      compressed: file_payload(attachment.compressed_file, attachment, "compressed")
    }
  end

  defp file_payload(%Files.File{} = file, attachment, variant) do
    %{
      name: file.filename,
      size: file.size_bytes,
      type: file.mime_type,
      url: "/api/bff/chat-drafts/#{attachment.chat_id}/attachments/#{attachment.id}/#{variant}"
    }
  end

  defp file_payload(_, _, _), do: nil
end
