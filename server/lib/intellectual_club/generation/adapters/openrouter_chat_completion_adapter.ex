defmodule IntellectualClub.Generation.Adapters.OpenRouterChatCompletionAdapter do
  @moduledoc false

  @behaviour IntellectualClub.Generation.ProviderAdapter

  alias IntellectualClub.Generation.Adapters.ChatAdapterHelpers
  alias IntellectualClub.Generation.RequestBuilder
  alias IntellectualClub.Generation.RequestPayload
  alias IntellectualClub.LlmCore.OpenRouterChatCompletionTrace

  @anthropic_tool_call_id_pattern ~r/^[a-zA-Z0-9_-]+$/
  @anthropic_tool_call_id_rewrite ~r/[^a-zA-Z0-9_-]+/

  @impl true
  def supports_cache_control?, do: true

  @impl true
  def build_initial_request(opts) when is_map(opts) do
    messages =
      opts
      |> Map.put(:provider_type, :openrouter_chat_completion)
      |> ChatAdapterHelpers.build_initial_messages()
      |> sanitize_messages_for_model(model_name: Map.get(opts, :model_name))

    raw_request =
      RequestBuilder.build_chat_completions_payload(
        Map.get(opts, :model_name),
        Map.get(opts, :parameters, %{}) || %{},
        messages,
        tools: Map.get(opts, :tools, [])
      )

    %{
      raw_request: raw_request,
      request_snapshot: request_snapshot(raw_request)
    }
  end

  @impl true
  def build_followup_request(opts) when is_map(opts) do
    context = Map.get(opts, :context, %{})
    runtime_step = Map.fetch!(opts, :runtime_step)
    previous_raw_request = RequestPayload.stringify_keys(runtime_step.raw_request || %{})

    followup =
      ChatAdapterHelpers.build_followup_messages(
        opts
        |> Map.put(:provider_type, :openrouter_chat_completion)
        |> Map.put(:cache_control_enabled, Map.get(context, :cache_control_enabled, false))
        |> Map.put(:history_length, Map.get(context, :history_length))
      )

    raw_request =
      RequestBuilder.build_chat_completions_payload(
        RequestPayload.model_name(previous_raw_request, Map.get(context, :model_name)),
        RequestPayload.parameters(previous_raw_request, Map.get(context, :parameters, %{})),
        sanitize_messages_for_model(followup.messages,
          model_name:
            RequestPayload.model_name(previous_raw_request, Map.get(context, :model_name))
        ),
        tools: Map.get(opts, :tools, [])
      )

    %{
      runtime_step: followup.runtime_step,
      raw_request: raw_request,
      request_snapshot: request_snapshot(raw_request)
    }
  end

  @impl true
  def request_snapshot(raw_request), do: ChatAdapterHelpers.request_snapshot(raw_request)

  @impl true
  def stream_generate(opts, emit) when is_map(opts) and is_function(emit, 1) do
    context = Map.get(opts, :context, %{})
    request_payload = Map.get(opts, :request_payload)

    base_url = Map.get(context, :provider_base_url)
    api_key = Map.get(context, :provider_api_key)
    model_name = RequestPayload.model_name(RequestPayload.stringify_keys(request_payload))

    cond do
      not is_binary(base_url) or String.trim(base_url) == "" ->
        emit_response_error(
          emit,
          Map.get(context, :provider_type),
          "Provider base URL is not set",
          request_payload
        )

      not is_binary(api_key) or String.trim(api_key) == "" ->
        emit_response_error(
          emit,
          Map.get(context, :provider_type),
          "Provider API key is not set",
          request_payload
        )

      not is_binary(model_name) or String.trim(model_name) == "" ->
        emit_response_error(
          emit,
          Map.get(context, :provider_type),
          "Configuration model_name is not set",
          request_payload
        )

      true ->
        OpenRouterChatCompletionTrace.stream_generate(
          %{
            base_url: base_url,
            api_key: api_key,
            request_payload: RequestPayload.stringify_keys(request_payload || %{}),
            timeout_ms: Map.get(opts, :timeout_ms, 300_000)
          },
          emit
        )
    end
  end

  defp emit_response_error(emit, provider, error_text, raw_request) do
    emit.(
      {:response_error,
       %{
         provider: provider,
         error_text: error_text,
         raw_request: raw_request,
         raw_response: nil
       }}
    )

    :ok
  end

  defp sanitize_messages_for_model(messages, model_name: model_name) when is_list(messages) do
    if model_requires_strict_tool_call_ids?(model_name) do
      sanitize_messages_for_anthropic(messages)
    else
      messages
    end
  end

  defp sanitize_messages_for_model(messages, _opts), do: messages

  defp model_requires_strict_tool_call_ids?(model_name) do
    model_name
    |> to_string()
    |> String.downcase()
    |> String.starts_with?("anthropic/")
  end

  defp sanitize_messages_for_anthropic(messages) do
    {id_map, _used} =
      Enum.reduce(messages, {%{}, MapSet.new()}, fn msg, {id_map, used} ->
        if is_map(msg) and Map.get(msg, "role") == "assistant" and
             is_list(Map.get(msg, "tool_calls")) do
          Enum.reduce(msg["tool_calls"], {id_map, used}, fn tool_call, {id_map, used} ->
            original = if is_map(tool_call), do: Map.get(tool_call, "id"), else: nil

            if is_binary(original) and original != "" and not Map.has_key?(id_map, original) do
              candidate = sanitize_tool_call_id_for_anthropic(original)
              {candidate, used} = ensure_unique_id(candidate, used)
              {Map.put(id_map, original, candidate), used}
            else
              {id_map, used}
            end
          end)
        else
          {id_map, used}
        end
      end)

    if map_size(id_map) == 0 do
      messages
    else
      Enum.map(messages, fn msg ->
        if is_map(msg) do
          rewrite_message_tool_call_ids(msg, id_map)
        else
          msg
        end
      end)
    end
  end

  defp sanitize_tool_call_id_for_anthropic(nil), do: "call"
  defp sanitize_tool_call_id_for_anthropic(""), do: "call"

  defp sanitize_tool_call_id_for_anthropic(value) when is_binary(value) do
    if Regex.match?(@anthropic_tool_call_id_pattern, value) do
      value
    else
      cleaned =
        value
        |> Regex.replace(@anthropic_tool_call_id_rewrite, "_")
        |> String.trim("_")

      if cleaned == "", do: "call", else: cleaned
    end
  end

  defp ensure_unique_id(candidate, used) do
    if MapSet.member?(used, candidate) do
      ensure_unique_id(candidate, used, 1)
    else
      {candidate, MapSet.put(used, candidate)}
    end
  end

  defp ensure_unique_id(base, used, suffix) do
    candidate = "#{base}_#{suffix}"

    if MapSet.member?(used, candidate) do
      ensure_unique_id(base, used, suffix + 1)
    else
      {candidate, MapSet.put(used, candidate)}
    end
  end

  defp rewrite_message_tool_call_ids(msg, id_map) do
    case Map.get(msg, "role") do
      "assistant" ->
        tool_calls = Map.get(msg, "tool_calls")

        if is_list(tool_calls) do
          new_tool_calls =
            Enum.map(tool_calls, fn tool_call ->
              if is_map(tool_call) do
                tc_id = Map.get(tool_call, "id")

                if is_binary(tc_id) and Map.has_key?(id_map, tc_id) do
                  Map.put(tool_call, "id", id_map[tc_id])
                else
                  tool_call
                end
              else
                tool_call
              end
            end)

          Map.put(msg, "tool_calls", new_tool_calls)
        else
          msg
        end

      "tool" ->
        tc_id = Map.get(msg, "tool_call_id")

        if is_binary(tc_id) and Map.has_key?(id_map, tc_id) do
          Map.put(msg, "tool_call_id", id_map[tc_id])
        else
          msg
        end

      _other ->
        msg
    end
  end
end
