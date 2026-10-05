defmodule IntellectualClub.ProviderStreamHelpers do
  @moduledoc """
  Helpers for provider adapter tests that stream events to the test process as
  `{:provider_event, event}` messages.

  Import explicitly: `import IntellectualClub.ProviderStreamHelpers`.
  """

  import ExUnit.Assertions

  alias IntellectualClub.Generation.RuntimeTrace

  @doc """
  Provider deadline (`timeout_ms`, `connect_timeout_ms`) for tests whose subject
  is not deadline handling.

  A localhost exchange with a test server takes well under a millisecond, but
  under the parallel partitions of `bin/server-test --all` a single request was
  measured to stall for up to ~0.8 s, so a production-like 1 s deadline made
  such tests fail with `error_kind: "timeout"` at random. Tests of timeout
  handling use a server that never answers (or a refused port) instead.
  """
  def provider_deadline_ms, do: 15_000

  @doc "Returns the `{:provider_event, event}` messages already in the mailbox, oldest first."
  def drain_provider_events(acc \\ []) do
    receive do
      {:provider_event, event} -> drain_provider_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  Runs `module.stream_generate(opts, callback)` to completion and returns the
  emitted events, oldest first. Asserts the provider contract shared by every
  adapter: no `:set_step_raw_request` trace is emitted and terminal events
  echo the original request payload as `raw_request`.
  """
  def run_and_capture_events!(module, opts) when is_atom(module) and is_map(opts) do
    parent = self()
    :ok = module.stream_generate(opts, fn event -> send(parent, {:provider_event, event}) end)

    events = drain_provider_events()
    refute Enum.any?(events, &match?({:trace, {:set_step_raw_request, _}}, &1))

    for {event, meta} <- events, event in [:response_complete, :response_error] do
      assert meta.raw_request == opts.request_payload
    end

    events
  end

  @doc """
  Runs `module.stream_generate(opts, callback)` expecting a provider error and
  returns it. Asserts that the error carries the original request payload and
  that no `:set_step_raw_request` trace was emitted.
  """
  def run_and_capture_error!(module, opts) when is_atom(module) and is_map(opts) do
    parent = self()
    :ok = module.stream_generate(opts, fn event -> send(parent, {:provider_event, event}) end)

    assert_receive {:provider_event, {:response_error, error}}, 2000
    assert error.raw_request == opts.request_payload
    refute_receive {:provider_event, {:trace, {:set_step_raw_request, _}}}, 0
    error
  end

  @doc "Applies the `{:trace, event}` entries of `events` to a new runtime step."
  def trace_step(events) when is_list(events) do
    Enum.reduce(events, RuntimeTrace.new_step(), fn
      {:trace, trace_event}, step -> RuntimeTrace.apply_event(step, trace_event)
      _event, step -> step
    end)
  end
end
