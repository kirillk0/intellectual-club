defmodule IntellectualClub.WaitHelpers do
  @moduledoc """
  Polling helpers for conditions that are not observable through messages.

  Prefer deterministic synchronization (monitors, `assert_receive`, explicit
  barriers) where the code under test offers it; use these helpers only for
  state that can only be polled (database rows, process state, registries).
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @default_timeout 1_000
  @default_interval 10

  @doc """
  Calls `fun` until it returns a truthy value and returns that value; fails
  the test when the timeout elapses.

  The second argument is either the timeout in milliseconds or options:

    * `:timeout` — total time budget in milliseconds (default #{@default_timeout});
    * `:interval` — pause between attempts in milliseconds (default #{@default_interval});
    * `:message` — failure message.
  """
  def wait_until(fun, opts \\ [])

  def wait_until(fun, timeout) when is_function(fun, 0) and is_integer(timeout) do
    wait_until(fun, timeout: timeout)
  end

  def wait_until(fun, opts) when is_function(fun, 0) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    interval = Keyword.get(opts, :interval, @default_interval)
    message = Keyword.get(opts, :message, "Condition was not met within #{timeout}ms")
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_until(fun, deadline, interval, message)
  end

  defp do_wait_until(fun, deadline, interval, message) do
    if result = fun.() do
      result
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk(message)
      else
        Process.sleep(interval)
        do_wait_until(fun, deadline, interval, message)
      end
    end
  end

  @doc """
  Waits until the chat message `message_id` (read as `actor`) has one of the
  `wanted` statuses (an atom or a list) and returns it.

  Options as in `wait_until/2` (defaults: `timeout: 4000`, `interval: 20`) plus:

    * `:load` — loads for the returned message (default `[]`);
    * `:stop_worker` — when `true`, also waits for the generation worker to
      stop (`wait_for_generation_worker_to_stop!/2`) before returning.
  """
  def wait_for_message_status!(message_id, actor, wanted, opts \\ []) do
    wanted = List.wrap(wanted)
    {load, opts} = Keyword.pop(opts, :load, [])
    {stop_worker?, opts} = Keyword.pop(opts, :stop_worker, false)

    opts =
      Keyword.merge(
        [
          timeout: 4_000,
          interval: 20,
          message: "Message #{message_id} did not reach #{inspect(wanted)}"
        ],
        opts
      )

    message =
      wait_until(
        fn ->
          message =
            Ash.get!(IntellectualClub.Chat.ChatMessage, message_id, actor: actor, load: load)

          message.status in wanted && message
        end,
        opts
      )

    if stop_worker?, do: wait_for_generation_worker_to_stop!(message_id)
    message
  end

  @doc """
  Waits until the background task `task_id` (read as `actor`) has `status` and
  returns it. Options as in `wait_until/2` (defaults: `timeout: 4000`, `interval: 20`).
  """
  def wait_for_background_task_status!(task_id, actor, status, opts \\ []) do
    opts =
      Keyword.merge(
        [
          timeout: 4_000,
          interval: 20,
          message: "Background task #{task_id} did not reach #{inspect(status)}"
        ],
        opts
      )

    wait_until(
      fn ->
        task = Ash.get!(IntellectualClub.BackgroundTasks.BackgroundTask, task_id, actor: actor)
        task.status == status && task
      end,
      opts
    )
  end

  @doc """
  Waits until the generation worker of `message_id` is no longer registered.
  Options as in `wait_until/2` (defaults: `timeout: 2000`, `interval: 20`).
  """
  def wait_for_generation_worker_to_stop!(message_id, opts \\ []) do
    opts =
      Keyword.merge(
        [timeout: 2_000, interval: 20, message: "Generation worker did not stop before timeout"],
        opts
      )

    wait_until(
      fn ->
        IntellectualClub.Generation.Supervisor.get_generation_state(message_id) == :not_found
      end,
      opts
    )

    :ok
  end
end
