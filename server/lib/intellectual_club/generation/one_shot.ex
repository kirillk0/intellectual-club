defmodule IntellectualClub.Generation.OneShot do
  @moduledoc """
  Runs a single provider request without persisting chat generation records.
  """

  alias IntellectualClub.Generation.RuntimeTrace
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.Providers.Common.Registry, as: ProviderRegistry

  @default_timeout_ms 300_000

  @spec generate(map() | nil, [map()], String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate(llm_configuration, history, system_prompt, opts \\ [])
      when is_list(history) and is_binary(system_prompt) and is_list(opts) do
    provider_type = provider_type_for_configuration(llm_configuration)
    adapter = ProviderRegistry.fetch_or_missing(provider_type)
    provider = provider_for_configuration(llm_configuration)
    timeout_ms = timeout_ms_for_configuration(llm_configuration)

    initial_request =
      adapter.build_initial_request(%{
        history: history,
        system_prompt: system_prompt,
        model_name: model_name_for_configuration(llm_configuration),
        parameters: parameters_for_configuration(llm_configuration),
        tools: [],
        supports_image_input: false,
        provider_type: provider_type,
        fix_role_alteration: fix_role_alteration_for_configuration(llm_configuration),
        cache_control_enabled: cache_control_enabled_for_configuration(adapter, llm_configuration)
      })

    context = %{
      provider_id: map_get(provider, :id),
      provider_type: provider_type,
      provider_base_url: map_get(provider, :base_url),
      provider_api_key: map_get(provider, :api_key),
      provider_auth_method: map_get(provider, :auth_method),
      provider_oauth_refresh_token: map_get(provider, :oauth_refresh_token),
      model_name: model_name_for_configuration(llm_configuration),
      parameters: parameters_for_configuration(llm_configuration),
      timeout_ms: timeout_ms
    }

    run_stream(adapter, context, initial_request.raw_request || %{},
      timeout_ms: timeout_ms,
      chunk_delay_ms: Keyword.get(opts, :chunk_delay_ms, 0)
    )
  end

  defp run_stream(adapter, context, raw_request, opts) do
    parent = self()
    ref = make_ref()
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    task =
      Task.async(fn ->
        adapter.stream_generate(
          %{
            context: context,
            request_payload: raw_request,
            timeout_ms: timeout_ms,
            chunk_delay_ms: Keyword.get(opts, :chunk_delay_ms, 0)
          },
          fn event -> send(parent, {:one_shot_provider_event, ref, event}) end
        )
      end)

    step = RuntimeTrace.new_step(raw_request: raw_request, status: :waiting_provider)
    collect_stream(ref, task, step, timeout_ms + 5_000)
  end

  defp collect_stream(ref, %Task{} = task, %RuntimeTrace.Step{} = step, timeout_ms) do
    receive do
      {:one_shot_provider_event, ^ref, {:trace, trace_event}} ->
        step = RuntimeTrace.apply_event(step, trace_event)
        collect_stream(ref, task, step, timeout_ms)

      {:one_shot_provider_event, ^ref, {:response_complete, _meta}} ->
        finish_task(task)
        text = RuntimeTrace.text_for_item_type(step, :answer) |> String.trim()

        if text == "" do
          {:error, :empty_response}
        else
          {:ok, text}
        end

      {:one_shot_provider_event, ^ref, {:response_error, meta}} ->
        finish_task(task)
        {:error, error_text(meta)}

      {task_ref, :ok} when task_ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        text = RuntimeTrace.text_for_item_type(step, :answer) |> String.trim()

        if text == "" do
          {:error, :stream_finished_without_response}
        else
          {:ok, text}
        end

      {:DOWN, task_ref, :process, _pid, :normal} when task_ref == task.ref ->
        text = RuntimeTrace.text_for_item_type(step, :answer) |> String.trim()

        if text == "" do
          {:error, :stream_finished_without_response}
        else
          {:ok, text}
        end

      {:DOWN, task_ref, :process, _pid, reason} when task_ref == task.ref ->
        {:error, reason}
    after
      timeout_ms ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp finish_task(%Task{} = task) do
    receive do
      {task_ref, :ok} when task_ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        :ok

      {:DOWN, task_ref, :process, _pid, _reason} when task_ref == task.ref ->
        :ok
    after
      1_000 ->
        Task.shutdown(task, :brutal_kill)
        :ok
    end
  end

  defp error_text(meta) when is_map(meta) do
    Map.get(meta, :error_text) || Map.get(meta, "error_text") || inspect(meta)
  end

  defp error_text(other), do: inspect(other)

  defp provider_type_for_configuration(%LlmConfiguration{provider: %{type: type}}),
    do: normalize_provider_type(type)

  defp provider_type_for_configuration(%{provider: %{type: type}}),
    do: normalize_provider_type(type)

  defp provider_type_for_configuration(_other), do: "demo"

  defp provider_for_configuration(%LlmConfiguration{provider: provider}) when is_map(provider),
    do: provider

  defp provider_for_configuration(%{provider: provider}) when is_map(provider), do: provider
  defp provider_for_configuration(_other), do: %{}

  defp model_name_for_configuration(%LlmConfiguration{model_name: model_name}), do: model_name
  defp model_name_for_configuration(%{model_name: model_name}), do: model_name
  defp model_name_for_configuration(_other), do: nil

  defp parameters_for_configuration(%LlmConfiguration{parameters: params}) when is_map(params),
    do: params

  defp parameters_for_configuration(%{parameters: params}) when is_map(params), do: params
  defp parameters_for_configuration(_other), do: %{}

  defp timeout_ms_for_configuration(%LlmConfiguration{timeout_seconds: seconds}),
    do: timeout_ms(seconds)

  defp timeout_ms_for_configuration(%{timeout_seconds: seconds}), do: timeout_ms(seconds)
  defp timeout_ms_for_configuration(_other), do: @default_timeout_ms

  defp timeout_ms(seconds) when is_integer(seconds) and seconds > 0, do: seconds * 1000
  defp timeout_ms(_seconds), do: @default_timeout_ms

  defp fix_role_alteration_for_configuration(%LlmConfiguration{fix_role_alteration: value}),
    do: value == true

  defp fix_role_alteration_for_configuration(%{fix_role_alteration: value}), do: value == true
  defp fix_role_alteration_for_configuration(_other), do: false

  defp cache_control_enabled_for_configuration(adapter, llm_configuration) do
    adapter.supports_cache_control?() and
      bool_true?(map_get(llm_configuration, :supports_cache_control))
  rescue
    _exception -> false
  end

  defp bool_true?(value), do: value in [true, "true", 1]

  defp normalize_provider_type(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_provider_type(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> "demo"
      type -> type
    end
  end

  defp normalize_provider_type(_value), do: "demo"

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp map_get(_map, _key), do: nil
end
