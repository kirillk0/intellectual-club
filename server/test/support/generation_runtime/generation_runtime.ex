defmodule IntellectualClub.Test.GenerationRuntime do
  @moduledoc """
  Shared setup for Generation runtime tests (Worker, persistence, lease,
  steering): a generating assistant message driven by
  `IntellectualClub.Test.GenerationRuntime.ScriptedAdapter`, Worker start and
  control helpers, durable-state readers and SQL failure injection.

      import IntellectualClub.Test.GenerationRuntime

      fixture = generation_fixture!()
      gen = start_generation!(fixture)
      send(gen.provider, {:complete, :answer})
      assert_worker_stopped!(gen.worker)

  Fixture maps carry `:actor`, `:chat`, `:configuration`, `:message`,
  `:step_id` and the Worker `:context`.
  """

  import ExUnit.Assertions
  import IntellectualClub.AccountsFixtures, only: [user_fixture: 0]
  import IntellectualClub.ChatFixtures, only: [create_chat!: 2, create_generating_message!: 3]
  import IntellectualClub.LlmFixtures, only: [create_configuration!: 2]

  alias IntellectualClub.Chat.{ChatMessage, ChatMessageItem, ChatMessageStep, QueuedMessages}
  alias IntellectualClub.Generation.{Lease, Persistence, Worker}
  alias IntellectualClub.Llm.LlmUsageRecord
  alias IntellectualClub.Repo
  alias IntellectualClub.Test.GenerationRuntime.ScriptedAdapter
  alias IntellectualClub.TestSupport.WebSearchServer
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @timeout 5_000

  @doc """
  Creates a user, an LLM configuration, a chat, a user message and its
  generating assistant reply with step 1 started for the provider request.

  Options:
    * `:actor`, `:chat` — reuse an existing user and chat (the chat keeps its
      own LLM configuration);
    * `:prompt` — the user message text (default `"Initial request"`);
    * `:request` — the step 1 request (default: the prompt as one user message);
    * `:context` — Worker context overrides (map or keyword list).
  """
  def generation_fixture!(opts \\ []) do
    actor = Keyword.get_lazy(opts, :actor, fn -> user_fixture().user end)
    prompt = Keyword.get(opts, :prompt, "Initial request")

    configuration =
      create_configuration!(actor, %{
        model_name: "test-model",
        note: nil,
        timeout_seconds: 5,
        provider_attrs: %{type: :openrouter_chat_completion, base_url: "http://localhost:1"}
      })

    chat =
      Keyword.get_lazy(opts, :chat, fn ->
        create_chat!(actor, %{llm_configuration_id: configuration.id})
      end)

    message =
      create_generating_message!(actor, chat, %{
        user_text: prompt,
        llm_configuration_id: configuration.id,
        token_count: 0
      })

    request =
      Keyword.get(opts, :request, %{
        "model" => "test-model",
        "messages" => [%{"role" => "user", "content" => prompt}],
        "stream" => true
      })

    step_id = Persistence.ensure_step_started!(message.id, request)

    context =
      Map.merge(
        %{
          owner_id: actor.id,
          chat_id: chat.id,
          message_id: message.id,
          step_id: step_id,
          provider_type: "test",
          adapter_module: ScriptedAdapter,
          request_payload: request,
          timeout_ms: @timeout,
          chunk_delay_ms: 0,
          test_pid: self(),
          test_attempts: :counters.new(1, []),
          tool_instances_by_alias: %{},
          max_tool_rounds: 8,
          tools_payload: []
        },
        Map.new(Keyword.get(opts, :context, %{}))
      )

    %{
      actor: actor,
      chat: chat,
      configuration: configuration,
      message: message,
      step_id: step_id,
      context: context
    }
  end

  @doc "Returns `fixture` with Worker context overrides merged in."
  def with_context(fixture, overrides) do
    %{fixture | context: Map.merge(fixture.context, Map.new(overrides))}
  end

  @doc """
  Starts a temporary Worker for `fixture` under the test supervisor. Acquires a
  lease unless `opts` already carries `:lease`. Returns the Worker pid.
  """
  def start_worker!(fixture, overrides \\ [], opts \\ %{}) do
    context = Map.merge(fixture.context, Map.new(overrides))

    opts =
      if Map.has_key?(opts, :lease) do
        opts
      else
        assert {:ok, lease} = Lease.acquire(fixture.message.id)
        Map.merge(opts, %{lease: lease, lease_owner: self()})
      end

    ExUnit.Callbacks.start_supervised!(%{
      id: {Worker, fixture.message.id, make_ref()},
      start: {Worker, :start_link, [Map.put(opts, :context, context)]},
      restart: :temporary
    })
  end

  @doc """
  Acquires a lease, starts the Worker and waits for its first provider request
  (which must be the step 1 request). Returns `fixture` with `:lease`,
  `:worker`, `:monitor`, `:provider`, `:provider_monitor` and `:initial_state`.
  """
  def start_generation!(fixture, overrides \\ []) do
    fixture = with_context(fixture, overrides)
    assert {:ok, lease} = Lease.acquire(fixture.message.id)
    worker = start_worker!(fixture, [], %{lease: lease, lease_owner: self()})
    monitor = Process.monitor(worker)
    {provider, request} = await_provider!(fixture)
    assert request == fixture.context.request_payload

    Map.merge(fixture, %{
      lease: lease,
      worker: worker,
      monitor: monitor,
      provider: provider,
      provider_monitor: Process.monitor(provider),
      initial_state: :sys.get_state(worker)
    })
  end

  @doc "Runs `fun.(lease)` while holding a generation lease of `message_id`."
  def with_generation_lease(message_id, fun) when is_function(fun, 1) do
    assert {:ok, lease} = Lease.acquire(message_id)

    try do
      fun.(lease)
    after
      Lease.release(lease)
    end
  end

  @doc "Waits for the next provider attempt of `fixture`; returns `{provider, request}`."
  def await_provider!(fixture, timeout \\ @timeout) do
    message_id = fixture.message.id
    assert_receive {:provider_started, ^message_id, provider, request}, timeout
    {provider, request}
  end

  @doc "Asserts that no provider attempt of `fixture` has started."
  def refute_provider_started(fixture) do
    message_id = fixture.message.id
    refute_receive {:provider_started, ^message_id, _provider, _request}, 0
  end

  @doc "Waits until the adapter prepared a tool follow-up request for `fixture`."
  def await_followup_prepared!(fixture) do
    message_id = fixture.message.id
    assert_receive {:followup_prepared, ^message_id}, @timeout
    :ok
  end

  def refute_followup_prepared(fixture) do
    message_id = fixture.message.id
    refute_receive {:followup_prepared, ^message_id}, 0
  end

  @doc """
  Waits until a traced (`trace_receives!/1`) Worker receives a failed
  failure-resolution result; returns the failure.
  """
  def await_failed_resolution!(worker) do
    assert_receive {:trace, ^worker, :receive,
                    {_ref, {:persistence_result, %{kind: :failure_resolution}, {:error, failure}}}},
                   @timeout

    failure
  end

  @doc "Waits until the monitored Worker stops with `reason` (default `:normal`)."
  def assert_worker_stopped!(worker, reason \\ :normal) do
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, ^reason}, @timeout
    :ok
  end

  @doc "Sends a `GenServer.call` request without waiting; returns the reply ref."
  def command(worker, command) do
    ref = make_ref()
    send(worker, {:"$gen_call", {self(), ref}, command})
    ref
  end

  @doc "Cancels a running Worker and waits for its normal exit."
  def cancel_worker!(worker) do
    monitor = Process.monitor(worker)
    assert Worker.cancel_and_wait(worker) == :ok
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, @timeout
    :ok
  end

  @doc "Enqueues a steer for the generation; notifies `worker` when given."
  def enqueue_steer!(fixture, text, worker \\ nil) do
    assert {:ok, queued} = QueuedMessages.enqueue_steer(fixture.message.id, text, fixture.actor)
    if worker, do: Worker.queue_changed(worker)
    queued
  end

  @doc """
  Starts tracing the messages `worker` receives: the test then gets
  `{:trace, worker, :receive, message}` for each of them.
  """
  def trace_receives!(worker) do
    :erlang.trace(worker, true, [:receive])
    :ok
  end

  @doc """
  Fires the pending failure-resolution retry timer of a `:recovering` Worker
  right away (the same message the timer would deliver).
  """
  def retry_failure_resolution_now!(worker) do
    assert %{failure_retry_timer: {timer, token}, phase: :recovering} = :sys.get_state(worker)
    Process.cancel_timer(timer)
    send(worker, {:retry_failure_resolution, token})
    :ok
  end

  # Durable state readers

  def message!(fixture, load \\ []) do
    Ash.get!(ChatMessage, fixture.message.id, actor: fixture.actor, load: load)
  end

  def step!(fixture, step_id \\ nil, load \\ []) do
    Ash.get!(ChatMessageStep, step_id || fixture.step_id, actor: fixture.actor, load: load)
  end

  @doc "Steps of the generation ordered by sequence."
  def steps!(fixture) do
    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^fixture.message.id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(actor: fixture.actor)
  end

  @doc "Items of `type` across all steps of the generation, with contents."
  def items!(fixture, type) do
    step_ids = Enum.map(steps!(fixture), & &1.id)

    ChatMessageItem
    |> Ash.Query.filter(chat_message_step_id in ^step_ids and type == ^type)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(:contents)
    |> Ash.read!(actor: fixture.actor)
  end

  @doc "Text contents of the answer items across all steps."
  def answers!(fixture) do
    fixture
    |> items!(:answer)
    |> Enum.flat_map(& &1.contents)
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.map(& &1.content_text)
  end

  @doc "The single usage record of a step (default: step 1)."
  def usage!(fixture, step_id \\ nil) do
    step_id = step_id || fixture.step_id

    assert [usage] =
             LlmUsageRecord
             |> Ash.Query.filter(chat_message_step_id_snapshot == ^step_id)
             |> Ash.read!(actor: fixture.actor)

    usage
  end

  @doc "Usage records of the generation ordered by step sequence."
  def usage_records!(fixture) do
    message_id = fixture.message.id

    LlmUsageRecord
    |> Ash.Query.filter(chat_message_id_snapshot == ^message_id)
    |> Ash.Query.sort(step_sequence: :asc)
    |> Ash.read!(actor: fixture.actor)
  end

  # Tools

  @doc """
  Starts a Brave-compatible web search server handled by `handler`
  (`fn path, payload -> {status, body} | {:wait, pid} end`) and returns a
  `native-web-search` tool instance pointing at it. Requests are reported to
  the test as `{:web_request, path, payload, headers}`.
  """
  def web_search_tool!(handler) do
    {_base_url, port} =
      IntellectualClub.TestHttpServer.start_http_server!(
        {WebSearchServer, handler: handler, test_pid: self()}
      )

    %ToolInstance{
      type: "native-web-search",
      config: %{
        "providers" => ["brave"],
        "provider_options" => %{"brave" => %{"api_base_url" => "http://127.0.0.1:#{port}/brave"}}
      },
      secrets: %{"brave_api_key" => "test-key"}
    }
  end

  # SQL failure injection

  @doc """
  Makes the first `count` rows matching `condition` (SQL over `NEW`/`OLD`) of a
  `timing` (e.g. `"BEFORE UPDATE"`) statement on `table` raise SQLSTATE `code`.
  Returns a handle for `sql_attempts/1`, which counts the matching attempts.

  The trigger runs inside the real transaction; `nextval` is nontransactional,
  so rolled-back attempts are counted too. All DDL is sandbox-local.
  """
  def inject_sql_failure!(table, timing, condition, code, count \\ 1_000_000) do
    name = "test_failure_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE TEMP SEQUENCE #{name}")

    Repo.query!("""
    CREATE FUNCTION pg_temp.#{name}() RETURNS trigger AS $$
    BEGIN
      IF #{condition} THEN
        IF nextval('pg_temp.#{name}') <= #{count} THEN
          RAISE EXCEPTION 'Injected failure #{name}' USING ERRCODE = '#{code}';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER #{name} #{timing} ON #{table}
    FOR EACH ROW EXECUTE FUNCTION pg_temp.#{name}()
    """)

    %{name: name, table: table}
  end

  def sql_attempts(%{name: name}) do
    %{rows: [[attempts, called?]]} =
      Repo.query!("SELECT last_value, is_called FROM pg_temp.#{name}")

    if called?, do: attempts, else: 0
  end

  def remove_sql_failure!(%{name: name, table: table}) do
    Repo.query!("DROP TRIGGER #{name} ON #{table}")
    :ok
  end
end
