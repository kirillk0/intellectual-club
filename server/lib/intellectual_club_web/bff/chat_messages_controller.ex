defmodule IntellectualClubWeb.Bff.ChatMessagesController do
  @moduledoc """
  Message-oriented BFF endpoints for the SPA.
  """

  use IntellectualClubWeb, :controller

  require Logger

  alias IntellectualClub.Chat.Bookmarking
  alias IntellectualClub.Chat.ContentFiles
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.ChatMessageContent
  alias IntellectualClub.Chat.ChatMessageItem
  alias IntellectualClub.Chat.ChatMessageStep
  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Persistence, as: GenerationPersistence
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.TokenCounter
  alias IntellectualClubWeb.Bff.ChatAttachments
  alias IntellectualClubWeb.Bff.ChatUploadPolicy
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.ImageControllerHelpers
  alias IntellectualClubWeb.Bff.Loads
  alias IntellectualClubWeb.Bff.Serializer

  def poll(conn, %{"id" => id} = _params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      message_id = String.to_integer(id)

      with {:ok, _message} <- Ash.get(ChatMessage, message_id, actor: actor) do
        case GenerationSupervisor.poll_generation(message_id, %{}, []) do
          {:ok, runtime} ->
            message = load_persisted_message(message_id, actor)
            steps = serialize_message_steps(message)
            current_step = Serializer.normalize_runtime_step_for_client(runtime.step)

            json(conn, %{
              message_id: message_id,
              runtime: true,
              status: Atom.to_string(runtime.status),
              current_step: current_step,
              steps: steps,
              token_count: if(message, do: message.token_count, else: nil),
              error_detail: if(message, do: message.error_detail, else: nil),
              finished_at:
                if(message, do: Serializer.datetime_iso(message.finished_at), else: nil)
            })

          :not_found ->
            render_poll_fallback(conn, message_id, actor)
        end
      else
        {:error, error} -> render_access_error(conn, error)
      end
    end
  end

  def cancel(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      message_id = String.to_integer(id)

      with {:ok, _message} <- fetch_owned_message(message_id, actor) do
        case GenerationSupervisor.cancel_generation(message_id) do
          :not_found -> json(conn, %{status: "not_found"})
          _other -> json(conn, %{status: "ok"})
        end
      else
        {:error, error} -> render_access_error(conn, error)
      end
    end
  end

  def retry_last_step(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      message_id = String.to_integer(id)

      with {:ok, _message} <- fetch_owned_message(message_id, actor) do
        case GenerationSupervisor.retry_last_step(message_id, actor: actor) do
          {:ok, context} ->
            render_retry_generation(conn, context, actor)

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Message not found"})

          {:error, :assistant_only} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Only assistant messages can be retried."})

          {:error, :invalid_status} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Message must be in error or canceled state."})

          {:error, :no_steps_to_retry} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "No steps to retry."})

          {:error, :invalid_step_request} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Step request payload is unavailable."})

          {:error, :configuration_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Configuration not found."})

          {:error, :already_running} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Message generation is already running."})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to retry generation: #{inspect(reason)}"})

          other ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to retry generation: #{inspect(other)}"})
        end
      else
        {:error, error} -> render_access_error(conn, error)
      end
    end
  end

  def retry_from_step(conn, %{"message_id" => message_id, "step_id" => step_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      message_id = String.to_integer(message_id)
      step_id = String.to_integer(step_id)

      with {:ok, _message} <- fetch_owned_message(message_id, actor) do
        case GenerationSupervisor.retry_from_step(message_id, step_id, actor: actor) do
          {:ok, context} ->
            render_retry_generation(conn, context, actor)

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Message not found"})

          {:error, :step_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Step not found"})

          {:error, :assistant_only} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Only assistant messages can be retried."})

          {:error, :invalid_status} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Retry from this step is available after generation stops."})

          {:error, :no_steps_to_retry} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "No steps to retry."})

          {:error, :invalid_step_request} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Step request payload is unavailable."})

          {:error, :configuration_not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Configuration not found."})

          {:error, :already_running} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Message generation is already running."})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to retry generation: #{inspect(reason)}"})

          other ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to retry generation: #{inspect(other)}"})
        end
      else
        {:error, error} -> render_access_error(conn, error)
      end
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      message_id = String.to_integer(id)

      with {:ok, message} <- fetch_owned_message(message_id, actor) do
        case Threads.delete_message_keep_children(message.chat_id, message_id, actor) do
          {:ok, _meta} ->
            {messages, branch_meta_by_id} = load_branch(message.chat_id, actor)

            json(conn, %{
              branch: serialize_branch(messages, branch_meta_by_id, actor)
            })

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to delete message: #{inspect(reason)}"})
        end
      else
        {:error, error} -> render_access_error(conn, error)
      end
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      message_id = String.to_integer(id)

      with {:ok, _owned_message} <- fetch_owned_message(message_id, actor) do
        message =
          Ash.get!(ChatMessage, message_id,
            actor: actor,
            load: Loads.message_tree(),
            strict?: true
          )

        if message.status == :generating do
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Cannot edit a generating message."})
        else
          wanted_type = wanted_item_type(message.role)
          editable_contents = editable_text_contents(message, wanted_type)

          editable_media = editable_media_contents(message, media_item_type(message.role))
          upload_policy = ChatUploadPolicy.load_for_chat(message.chat_id, actor)

          with {:ok, text_updates} <-
                 parse_message_text_update(params, editable_contents, allow_legacy?: true),
               {:ok, media_removals, prepared_uploads} <-
                 parse_message_media_update(params, editable_media),
               {:ok, :updated} <-
                 ChatAttachments.with_prepared_file_ids(
                   message.chat_id,
                   actor,
                   upload_policy,
                   prepared_uploads,
                   fn media_additions ->
                     apply_message_update(
                       message_id,
                       message,
                       actor,
                       text_updates,
                       media_removals,
                       media_additions
                     )
                   end
                 ) do
            {messages, branch_meta_by_id} = load_branch(message.chat_id, actor)

            json(conn, %{
              branch: serialize_branch(messages, branch_meta_by_id, actor)
            })
          else
            {:error, error_message} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: error_message})
          end
        end
      else
        {:error, error} -> render_access_error(conn, error)
      end
    end
  end

  def step_raw(conn, %{"message_id" => message_id, "step_id" => step_id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      message_id = String.to_integer(message_id)
      step_id = String.to_integer(step_id)
      kind = Map.get(params, "kind", "both")

      step = Ash.get!(IntellectualClub.Chat.ChatMessageStep, step_id, actor: actor)

      if step.chat_message_id != message_id do
        conn
        |> put_status(:not_found)
        |> json(%{error: "Step not found"})
      else
        payload =
          case kind do
            "request" ->
              %{id: step.id, sequence: step.sequence, raw_request: step.raw_request}

            "response" ->
              %{id: step.id, sequence: step.sequence, raw_response: step.raw_response}

            _ ->
              %{
                id: step.id,
                sequence: step.sequence,
                raw_request: step.raw_request,
                raw_response: step.raw_response
              }
          end

        json(conn, %{step: payload})
      end
    end
  end

  def content_full(conn, %{"message_id" => message_id, "content_id" => content_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      message_id = String.to_integer(message_id)
      content_id = String.to_integer(content_id)

      load = [chat_message_item: [chat_message_step: [:chat_message]]]
      content = Ash.get!(ChatMessageContent, content_id, actor: actor, load: load)

      step =
        case Map.get(content, :chat_message_item) do
          %{chat_message_step: chat_message_step} -> chat_message_step
          _other -> nil
        end

      if step && step.chat_message_id == message_id do
        json(conn, %{
          content: %{
            id: content.id,
            kind: to_string(content.kind || ""),
            content_text: to_string(content.content_text || "")
          }
        })
      else
        conn
        |> put_status(:not_found)
        |> json(%{error: "Content not found"})
      end
    end
  end

  def content_file(conn, %{"message_id" => message_id, "content_id" => content_id}) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      message_id = String.to_integer(message_id)
      content_id = String.to_integer(content_id)

      load = [:file, chat_message_item: [chat_message_step: [:chat_message]]]
      content = Ash.get!(ChatMessageContent, content_id, actor: actor, load: load)

      step =
        content.chat_message_item &&
          content.chat_message_item.chat_message_step

      if is_nil(step) or step.chat_message_id != message_id or not Media.media_content?(content) do
        conn
        |> put_status(:not_found)
        |> json(%{error: "Content not found"})
      else
        case ContentFiles.load_payload_for_content(content) do
          {:ok, {_content, file, payload}} ->
            disposition =
              if Media.image_mime_type?(file.mime_type), do: :inline, else: :attachment

            ImageControllerHelpers.send_loaded_file(conn, file, payload, disposition: disposition)

          {:error, _reason} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Content not found"})
        end
      end
    end
  end

  defp load_branch(chat_id, actor) when is_integer(chat_id) do
    {messages, branch_meta} =
      Threads.active_branch_with_meta(chat_id, actor,
        load: Loads.message_tree(),
        strict?: true
      )

    branch_meta_by_id = Map.new(branch_meta, fn node -> {node.id, node} end)
    {messages, branch_meta_by_id}
  end

  defp render_retry_generation(conn, context, actor) when is_map(context) do
    {messages, branch_meta_by_id} = load_branch(context.chat_id, actor)

    json(conn, %{
      branch: serialize_branch(messages, branch_meta_by_id, actor),
      generation: %{message_id: context.message_id}
    })
  end

  defp serialize_branch(messages, branch_meta_by_id, actor) do
    bookmarked_message_ids =
      messages
      |> Enum.map(& &1.id)
      |> Bookmarking.bookmarked_message_id_set(actor)

    Enum.map(messages, &Serializer.branch_message(&1, branch_meta_by_id, bookmarked_message_ids))
  end

  defp wanted_item_type(:user), do: :input
  defp wanted_item_type(:assistant), do: :answer
  defp wanted_item_type("user"), do: :input
  defp wanted_item_type("assistant"), do: :answer
  defp wanted_item_type(_other), do: :other

  defp media_item_type(:user), do: :input
  defp media_item_type("user"), do: :input
  defp media_item_type(:assistant), do: :artifact
  defp media_item_type("assistant"), do: :artifact
  defp media_item_type(_other), do: :other

  defp editable_text_contents(message, wanted_type)
       when is_map(message) and wanted_type in [:input, :answer, :other] do
    steps = Map.get(message, :steps) || []

    steps
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn step ->
      items = Map.get(step, :items) || []

      items
      |> Enum.sort_by(&sort_seq/1)
      |> Enum.filter(fn item ->
        Map.get(item, :type) == wanted_type
      end)
    end)
    |> Enum.flat_map(fn item ->
      contents = Map.get(item, :contents) || []

      contents
      |> Enum.filter(fn content -> Map.get(content, :kind) in [:text, "text"] end)
      |> Enum.sort_by(&sort_seq/1)
    end)
  end

  defp editable_media_contents(message, wanted_type)
       when is_map(message) and wanted_type in [:input, :artifact, :other] do
    steps = Map.get(message, :steps) || []

    steps
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn step ->
      items = Map.get(step, :items) || []

      items
      |> Enum.sort_by(&sort_seq/1)
      |> Enum.filter(fn item ->
        Map.get(item, :type) == wanted_type
      end)
    end)
    |> Enum.flat_map(fn item ->
      contents = Map.get(item, :contents) || []

      contents
      |> Enum.filter(fn content -> Map.get(content, :kind) in [:media, "media"] end)
      |> Enum.sort_by(&sort_seq/1)
    end)
  end

  defp sort_seq(%{sequence: sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(%{"sequence" => sequence}) when is_integer(sequence), do: sequence
  defp sort_seq(_other), do: 0

  defp parse_message_text_update(params, editable_contents, opts)
       when is_map(params) and is_list(editable_contents) and is_list(opts) do
    allow_legacy? = Keyword.get(opts, :allow_legacy?, false)

    editable_contents =
      editable_contents
      |> Enum.filter(fn content ->
        case Map.get(content, :id) do
          id when is_integer(id) and id > 0 -> true
          _ -> false
        end
      end)

    editable_by_id = Map.new(editable_contents, &{&1.id, &1})
    editable_ids = Map.keys(editable_by_id) |> MapSet.new()

    cond do
      Map.has_key?(params, "contents") ->
        updates =
          params
          |> Map.get("contents")
          |> List.wrap()
          |> Enum.map(&normalize_content_update/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(fn {id, _text} -> id end)

        if updates == [] do
          {:error, "Missing contents update payload."}
        else
          unknown =
            updates
            |> Enum.map(fn {id, _text} -> id end)
            |> Enum.reject(&MapSet.member?(editable_ids, &1))

          if unknown != [] do
            {:error, "Some content ids cannot be edited."}
          else
            {:ok,
             Enum.map(updates, fn {id, text} ->
               {Map.fetch!(editable_by_id, id), text}
             end)}
          end
        end

      Map.has_key?(params, "contents_json") ->
        params
        |> Map.get("contents_json")
        |> decode_json_list()
        |> Enum.map(&normalize_content_update/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(fn {id, _text} -> id end)
        |> case do
          [] ->
            {:error, "Missing contents update payload."}

          updates ->
            unknown =
              updates
              |> Enum.map(fn {id, _text} -> id end)
              |> Enum.reject(&MapSet.member?(editable_ids, &1))

            if unknown != [] do
              {:error, "Some content ids cannot be edited."}
            else
              {:ok,
               Enum.map(updates, fn {id, text} ->
                 {Map.fetch!(editable_by_id, id), text}
               end)}
            end
        end

      allow_legacy? and Map.has_key?(params, "content") ->
        content_text = params |> Map.get("content", "") |> to_string()

        case editable_contents do
          [%ChatMessageContent{} = single] ->
            {:ok, [{single, content_text}]}

          [] ->
            {:error, "No editable text content found for this message."}

          _many ->
            {:error, "This message has multiple text contents; use contents[] payload."}
        end

      true ->
        {:ok, []}
    end
  end

  defp parse_message_media_update(params, editable_media)
       when is_map(params) and is_list(editable_media) do
    editable_media =
      editable_media
      |> Enum.filter(fn content ->
        case Map.get(content, :id) do
          id when is_integer(id) and id > 0 -> true
          _ -> false
        end
      end)

    editable_by_id = Map.new(editable_media, &{&1.id, &1})
    editable_ids = Map.keys(editable_by_id) |> MapSet.new()

    remove_ids =
      params
      |> media_removal_ids_param()
      |> Enum.map(&Helpers.parse_optional_integer/1)
      |> Enum.filter(&(is_integer(&1) and &1 > 0))
      |> Enum.uniq()

    with {:ok, prepared_uploads} <- ChatAttachments.parse_prepared_uploads(params),
         [] <-
           Enum.reject(remove_ids, fn id ->
             MapSet.member?(editable_ids, id)
           end) do
      removals = Enum.map(remove_ids, &Map.fetch!(editable_by_id, &1))
      {:ok, removals, prepared_uploads}
    else
      unknown when is_list(unknown) and unknown != [] ->
        {:error, "Some attachments cannot be edited."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp normalize_content_update(%{} = raw) do
    id =
      raw
      |> Map.get("id", Map.get(raw, :id))
      |> Helpers.parse_optional_integer()

    text =
      raw
      |> Map.get(
        "content_text",
        Map.get(raw, :content_text, Map.get(raw, "text", Map.get(raw, :text, "")))
      )
      |> to_string()

    if is_integer(id) and id > 0 do
      {id, text}
    else
      nil
    end
  end

  defp normalize_content_update(_other), do: nil

  defp media_removal_ids_param(params) when is_map(params) do
    cond do
      Map.has_key?(params, "remove_content_ids") ->
        List.wrap(Map.get(params, "remove_content_ids"))

      Map.has_key?(params, "remove_content_ids_json") ->
        params
        |> Map.get("remove_content_ids_json")
        |> decode_json_list()

      true ->
        []
    end
  end

  defp decode_json_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  defp decode_json_list(value) when is_list(value), do: value
  defp decode_json_list(_other), do: []

  defp ensure_media_item!(%ChatMessage{} = message, actor) do
    item_type = media_item_type(message.role)
    steps = (message.steps || []) |> Enum.sort_by(&sort_seq/1)

    step =
      List.last(steps) ||
        create_message_step!(message.id, Enum.max([0 | Enum.map(steps, &sort_seq/1)]) + 1, actor)

    existing_item =
      (step.items || [])
      |> Enum.sort_by(&sort_seq/1)
      |> Enum.find(fn item -> Map.get(item, :type) == item_type end)

    existing_item ||
      create_message_item!(
        step.id,
        Enum.max([0 | Enum.map(step.items || [], &sort_seq/1)]) + 1,
        item_type,
        actor
      )
  end

  defp create_message_step!(message_id, sequence, actor) do
    ChatMessageStep
    |> Ash.Changeset.for_create(:create, %{chat_message_id: message_id, sequence: sequence},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_message_item!(step_id, sequence, type, actor) do
    ChatMessageItem
    |> Ash.Changeset.for_create(
      :create,
      %{chat_message_step_id: step_id, sequence: sequence, type: type},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp next_content_sequence(item) when is_map(item) do
    item
    |> Map.get(:contents)
    |> case do
      contents when is_list(contents) -> contents
      _other -> []
    end
    |> Enum.map(&sort_seq/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp apply_message_update(
         message_id,
         %ChatMessage{} = message,
         actor,
         text_updates,
         media_removals,
         media_additions
       ) do
    Enum.each(text_updates, fn {content, text} ->
      content
      |> Ash.Changeset.for_update(:update, %{content_text: text}, actor: actor)
      |> Ash.update!(actor: actor)
    end)

    Enum.each(media_removals, fn content ->
      Ash.destroy!(content, actor: actor)
    end)

    if media_additions != [] do
      target_item = ensure_media_item!(message, actor)
      next_sequence = next_content_sequence(target_item)

      Enum.with_index(media_additions, next_sequence)
      |> Enum.each(fn {file_id, sequence} ->
        ChatMessageContent
        |> Ash.Changeset.for_create(
          :create,
          %{
            chat_message_item_id: target_item.id,
            sequence: sequence,
            kind: :media,
            file_id: file_id
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)
      end)
    end

    message =
      Ash.get!(ChatMessage, message_id,
        actor: actor,
        load: Loads.message_tree(),
        strict?: true
      )

    token_count =
      message
      |> message_primary_text()
      |> TokenCounter.estimate()

    _message =
      message
      |> Ash.Changeset.for_update(:update_token_count, %{token_count: token_count}, actor: actor)
      |> Ash.update!(actor: actor)

    {:ok, :updated}
  end

  defp message_primary_text(%ChatMessage{} = message) do
    wanted_type = wanted_item_type(message.role)
    steps = message.steps || []

    steps
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.flat_map(fn step ->
      items = Map.get(step, :items) || []
      Enum.sort_by(items, &sort_seq/1)
    end)
    |> Enum.filter(fn item -> Map.get(item, :type) == wanted_type end)
    |> Enum.map(&item_text/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n\n")
  end

  defp message_primary_text(_other), do: ""

  defp item_text(item) do
    contents = Map.get(item, :contents) || []

    contents
    |> Enum.filter(fn content -> Map.get(content, :kind) in [:text, "text"] end)
    |> Enum.sort_by(&sort_seq/1)
    |> Enum.map(fn content -> to_string(Map.get(content, :content_text) || "") end)
    |> Enum.join("")
  end

  defp render_poll_fallback(conn, message_id, actor) do
    load = Loads.message_tree()

    with {:ok, message} <-
           Ash.get(ChatMessage, message_id, actor: actor, load: load, strict?: true) do
      message =
        if message.status == :generating and actor_owns_message?(message, actor) do
          case GenerationSupervisor.resume_orphaned_message(message_id, actor: actor) do
            {:ok, _context} ->
              {:ok, fresh} =
                Ash.get(ChatMessage, message_id, actor: actor, load: load, strict?: true)

              fresh

            {:error, :already_running} ->
              {:ok, fresh} =
                Ash.get(ChatMessage, message_id, actor: actor, load: load, strict?: true)

              fresh

            {:error, reason} ->
              Logger.warning(
                "Poll fallback failed to resume orphaned generation message_id=#{message_id}: #{inspect(reason)}"
              )

              :ok = GenerationPersistence.cancel_orphaned_generating_message!(message_id)

              {:ok, fresh} =
                Ash.get(ChatMessage, message_id, actor: actor, load: load, strict?: true)

              fresh
          end
        else
          message
        end

      steps = serialize_message_steps(message)

      current_step =
        case steps do
          [] -> nil
          _ -> Enum.max_by(steps, &Map.get(&1, :sequence, 0))
        end

      json(conn, %{
        message_id: message_id,
        runtime: false,
        status: Atom.to_string(message.status),
        token_count: message.token_count,
        current_step: current_step,
        steps: steps,
        error_detail: message.error_detail,
        finished_at: Serializer.datetime_iso(message.finished_at)
      })
    else
      {:error, _error} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Message not found"})
    end
  end

  defp load_persisted_message(message_id, actor) when is_integer(message_id) do
    case Ash.get(ChatMessage, message_id,
           actor: actor,
           load: Loads.message_tree(),
           strict?: true
         ) do
      {:ok, message} ->
        message

      {:error, _error} ->
        nil
    end
  end

  defp serialize_message_steps(nil), do: []

  defp serialize_message_steps(message) do
    (message.steps || [])
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map(&Serializer.step/1)
  end

  defp fetch_owned_message(message_id, actor) do
    case Ash.get(ChatMessage, message_id, actor: actor) do
      {:ok, %ChatMessage{owner_id: owner_id} = message} when owner_id == actor.id ->
        {:ok, message}

      {:ok, %ChatMessage{}} ->
        {:error, :forbidden}

      {:ok, nil} ->
        {:error, :not_found}

      {:error, %Ash.Error.Query.NotFound{}} ->
        {:error, :not_found}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, :forbidden}

      {:error, error} ->
        {:error, error}
    end
  end

  defp actor_owns_message?(%ChatMessage{owner_id: owner_id}, %{id: actor_id}),
    do: is_integer(owner_id) and owner_id == actor_id

  defp actor_owns_message?(_message, _actor), do: false

  defp render_access_error(conn, :forbidden) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Forbidden"})
  end

  defp render_access_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Message not found"})
  end

  defp render_access_error(conn, %Ash.Error.Forbidden{}) do
    render_access_error(conn, :forbidden)
  end

  defp render_access_error(conn, %Ash.Error.Query.NotFound{}) do
    render_access_error(conn, :not_found)
  end

  defp render_access_error(conn, error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Exception.message(error)})
  end
end
