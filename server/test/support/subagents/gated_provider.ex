defmodule IntellectualClub.TestSupport.Subagents.GatedProvider do
  @moduledoc """
  Demo-compatible LLM provider whose stream waits for an explicit release.

  Lets a test observe a generation (and everything waiting on it) while it is
  provably still running, without timing assumptions:

      gate_generations!()
      configuration = create_gated_configuration!(actor)
      # ... start a generation in a chat that uses `configuration` ...
      gate = await_gated_generation!()
      # ... assert on the in-flight state ...
      release_gated_generation(gate)

  A gated stream first emits `partial_answer/0`, so the in-flight state has an
  answer item. Without `gate_generations!/0` the provider streams the demo
  answer at once.
  Only for `async: false` modules (the gate owner is stored in the
  application environment).
  """

  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType

  import ExUnit.Assertions, only: [flunk: 1]

  alias IntellectualClub.Llm.Providers.Demo

  @owner_key :subagents_gated_provider_owner
  @release_timeout_ms 10_000

  @impl true
  def type, do: "gated_test"

  @impl true
  def label, do: "Gated test provider"

  @impl true
  def metadata, do: Demo.metadata() |> Map.put(:type, type()) |> Map.put(:label, label())

  @impl true
  def validate_provider(_provider, _opts), do: :ok

  @impl true
  defdelegate list_models(provider), to: Demo

  @impl true
  defdelegate supports_cache_control?(), to: Demo

  @impl true
  defdelegate apply_standard_parameters(parameters, settings), to: Demo

  @impl true
  defdelegate map_request_images(request, acc, mapper), to: Demo

  @impl true
  defdelegate prepare_request(request, context), to: Demo

  @impl true
  defdelegate build_initial_request(opts), to: Demo

  @impl true
  defdelegate build_followup_request(opts), to: Demo

  @impl true
  defdelegate inject_steering(request, items, context), to: Demo

  @impl true
  defdelegate request_snapshot(request), to: Demo

  @impl true
  def stream_generate(opts, emit) do
    case Application.get_env(:intellectual_club, @owner_key) do
      owner when is_pid(owner) ->
        emit.({:trace, {:ensure_item, "answer", :answer, 1}})
        emit.({:trace, {:append_text, "answer", :answer, 1, partial_answer()}})
        ref = make_ref()
        send(owner, {:gated_generation_waiting, self(), ref})

        receive do
          {:release_gated_generation, ^ref} -> :ok
        after
          @release_timeout_ms -> :ok
        end

      _other ->
        :ok
    end

    Demo.stream_generate(Map.put_new(opts, :chunk_delay_ms, 0), emit)
  end

  @doc "Text a gated stream emits before it waits for the release."
  def partial_answer, do: "Gated partial answer. "

  @doc "Makes every gated stream of this test wait for `release_gated_generation/1`."
  def gate_generations! do
    IntellectualClub.TestEnv.put_app_env(@owner_key, self())
  end

  @doc "Creates an LLM configuration (and provider) of the gated type."
  def create_gated_configuration!(actor) do
    IntellectualClub.LlmFixtures.create_configuration!(actor,
      provider_attrs: %{name: "Gated provider", type: type()},
      model_name: "gated-model",
      context_length: 128_000
    )
  end

  @doc "Waits until a gated stream is waiting and returns its gate."
  def await_gated_generation!(timeout \\ 5_000) do
    receive do
      {:gated_generation_waiting, pid, ref} -> {pid, ref}
    after
      timeout -> flunk("No gated generation started within #{timeout}ms")
    end
  end

  @doc "Lets a waiting gated stream produce its answer."
  def release_gated_generation({pid, ref}) do
    send(pid, {:release_gated_generation, ref})
    :ok
  end
end
