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
  alias IntellectualClub.Generation.StepRequests
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

    request = StepRequests.normalize!(raw)
    adapter = Map.get(context, :adapter_module) || Map.get(context, :adapter)
    request = if adapter, do: PreparedRequest.prepare(adapter, request, context), else: request

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

    prepared =
      case RequestImages.prepare(request, scope, Keyword.take(opts, [:source_step_id])) do
        {:ok, prepared} ->
          prepared

        {:error, reason} ->
          raise ArgumentError, "Request image preparation failed: #{inspect(reason)}"
      end

    try do
      fun.(%{prepared | request: StepRequests.normalize!(prepared.request)})
    after
      case RequestImages.discard_staged_bindings(prepared.bindings) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to discard staged request images: #{inspect(reason)}")
      end
    end
  end
end
