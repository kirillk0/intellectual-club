defmodule IntellectualClub.Generation.PreparedRequests do
  @moduledoc """
  Finalizes logical requests and stages image pins before a step is published.

  The callback owns the publication transaction. Unattached staged files are
  discarded on callback exit; attached files remain owned by the step.

  When called inside an outer transaction, staging File rows and bindings join
  that transaction. A later outer rollback removes them together; a newly written
  unreferenced payload is safely reclaimed by the filesystem GarbageCollector.
  Callers staging before their outer transaction must retain the staging handle
  until its final outcome instead of using an early nested callback lifetime.
  """

  require Logger

  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Generation.RequestImages
  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.Llm.Providers.Common.PreparedRequest
  alias IntellectualClub.Tools.ExecutionContext

  def with_prepared!(%ChatMessage{} = message, raw, opts, fun)
      when is_list(opts) and is_function(fun, 1) do
    context = Keyword.get(opts, :request_context) || %{}

    if Map.get(context, :owner_id, message.owner_id) not in [nil, message.owner_id] or
         Map.get(context, :chat_id, message.chat_id) not in [nil, message.chat_id] do
      raise ArgumentError, "Request context does not belong to the message"
    end

    context =
      context
      |> Map.put(:owner_id, message.owner_id)
      |> Map.put(:chat_id, message.chat_id)
      |> Map.put(:message_id, message.id)

    adapter = Map.get(context, :adapter_module) || Map.get(context, :adapter)

    request =
      if adapter,
        do: PreparedRequest.prepare(adapter, raw, context),
        else: RequestPayload.json_keys!(raw)

    scope = %ExecutionContext{
      owner_id: message.owner_id,
      chat_id: message.chat_id,
      root_chat_id: Map.get(context, :conversation_affinity_id),
      message_id: message.id,
      assistant_message_id: message.id,
      provider_type: Map.get(context, :provider_type),
      available_file_external_ids: Map.get(context, :available_file_external_ids, [])
    }

    scope =
      case Keyword.get(opts, :image_scope) do
        nil ->
          scope

        %ExecutionContext{owner_id: owner_id} = source_scope when owner_id == message.owner_id ->
          source_scope

        _other ->
          raise ArgumentError, "Request image scope does not belong to the message owner"
      end

    image_opts = [
      source_step_id: Keyword.get(opts, :source_step_id),
      source_request: Keyword.get(opts, :previous_request),
      source_image_state: Keyword.get(opts, :source_image_state),
      cache: Keyword.get(opts, :image_cache, %{}),
      mapper: RequestImages.mapper(adapter),
      source_mapper: Keyword.get(opts, :source_mapper, RequestImages.mapper(adapter))
    ]

    prepared =
      case RequestImages.prepare(request, scope, image_opts) do
        {:ok, prepared} ->
          prepared

        {:error, reason} ->
          raise ArgumentError, "Request image preparation failed: #{inspect(reason)}"
      end

    try do
      prepared |> fun.() |> attach_image_state(prepared.image_state)
    after
      case RequestImages.discard_staged_bindings(prepared.bindings) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to discard staged request images: #{inspect(reason)}")
      end
    end
  end

  # This metadata is returned only after the publication callback succeeds. It is
  # private runtime state, not part of the immutable request or public snapshot.
  defp attach_image_state(%{step_id: step_id, raw_request: request} = result, image_state) do
    Map.put(
      result,
      :request_images,
      Map.merge(image_state, %{step_id: step_id, request: request})
    )
  end

  defp attach_image_state(%{step: %{id: step_id}, request: request} = result, image_state) do
    Map.put(
      result,
      :request_images,
      Map.merge(image_state, %{step_id: step_id, request: request})
    )
  end

  defp attach_image_state({:ok, result}, image_state),
    do: {:ok, attach_image_state(result, image_state)}

  defp attach_image_state(result, _image_state), do: result
end
