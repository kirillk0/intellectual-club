defmodule IntellectualClub.SubagentFixtures do
  @moduledoc """
  Fixtures for subagent (fork, spawn, handoff) and background task tests.

  A "parent" is a generating assistant message whose step holds the tool call
  that creates a subagent or a background task:

    * `create_source_tool_call!/1` — step 1 started with a bare `:tool_call`
      item, enough for background task provenance and lifecycle checks;
    * `create_parent_call!/4` — a chat bound to an agent management tool
      instance and a completed provider response with one persisted
      `agent_management__<primitive>` call, as the generation worker leaves it
      before the tool runs.

  `tool_call_context/3` builds the execution context of either shape, and
  `persist_receipt/5` writes the parent tool result under a generation fence,
  as the parent writer does.
  """

  import IntellectualClub.ChatFixtures
  import IntellectualClub.Fixtures
  import IntellectualClub.ToolsFixtures

  require Ash.Query

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.BackgroundTasks.BackgroundTask
  alias IntellectualClub.Chat.{Chat, ChatMessageStep}
  alias IntellectualClub.Generation.{Lease, Persistence, RuntimeTrace, ToolCall, ToolResult}
  alias IntellectualClub.Tools.{ExecutionContext, ExecutionResult}

  @terminal_statuses ["completed", "failed", "canceled"]

  @doc """
  Creates a generating assistant reply (user text `"Run"`) whose step 1 is
  started and holds a `:tool_call` item. Returns `%{chat:, message:, step:, item:}`.
  """
  def create_source_tool_call!(actor) do
    chat = create_empty_chat!(actor)
    message = create_generating_message!(actor, chat, user_text: "Run")
    step_id = Persistence.ensure_step_started!(message.id, 1, %{}, [])
    step = Ash.get!(ChatMessageStep, step_id, actor: actor)
    item = create_item!(actor, step, type: :tool_call)
    %{chat: chat, message: message, step: step, item: item}
  end

  @doc """
  Creates a parent generation that called `agent_management__<primitive>` with
  `args`. Returns `%{chat:, message:, step_id:, call:, tool_instance:}` where
  `call` is the persisted `IntellectualClub.Generation.ToolCall`.

  Options:

    * `:user_prompt` — text of the user message (default `"Run subagent"`);
    * `:tools` — `"tools"` of the step request;
    * `:chat` — attributes of the parent chat (e.g. `:llm_configuration_id`).
  """
  def create_parent_call!(actor, primitive, args, opts \\ []) do
    user_prompt = Keyword.get(opts, :user_prompt, "Run subagent")
    chat = create_chat!(actor, Keyword.get(opts, :chat, %{}))
    tool_instance = create_tool_instance!(actor, type: "native-agent-management")

    create_tool_function!(actor, tool_instance,
      name: to_string(primitive),
      parameters_schema: %{}
    )

    create_chat_tool_binding!(actor, chat, tool_instance)
    message = create_generating_message!(actor, chat, user_text: user_prompt)

    raw_request =
      %{
        "model" => "demo-model",
        "messages" => [%{"role" => "user", "content" => user_prompt}],
        "stream" => true
      }
      |> maybe_put("tools", Keyword.get(opts, :tools))

    step_id = Persistence.ensure_step_started!(message.id, 1, raw_request, [])

    runtime_step =
      RuntimeTrace.new_step(id: step_id, sequence: 1, raw_request: raw_request)
      |> add_runtime_tool_call(
        "#{primitive}_#{System.unique_integer([:positive])}",
        "agent_management__#{primitive}",
        args,
        1
      )
      |> RuntimeTrace.apply_event({:set_step_raw_response, %{"id" => "subagent-step-response"}})
      |> RuntimeTrace.apply_event({:set_step_response_final, true})

    %{tool_calls: [call]} = Persistence.persist_provider_completed!(message.id, runtime_step)

    %{chat: chat, message: message, step_id: step_id, call: call, tool_instance: tool_instance}
  end

  @doc """
  Adds a provider function call (`call_id`, `name`, `args`) as item `sequence`
  of a runtime trace step.
  """
  def add_runtime_tool_call(runtime_step, call_id, name, args, sequence) do
    runtime_step
    |> RuntimeTrace.apply_event({:ensure_item, "tc:" <> call_id, :tool_call, sequence})
    |> RuntimeTrace.apply_event(
      {:set_opaque, "tc:" <> call_id, :tool_call, 10_000,
       %{
         "tool_call_id" => call_id,
         "call_id" => call_id,
         "name" => name,
         "raw" => %{
           "id" => call_id,
           "type" => "function",
           "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
         }
       }}
    )
  end

  @doc """
  Builds the execution context of the tool call of `parent` (from
  `create_source_tool_call!/1` or `create_parent_call!/4`); `attrs` override fields.
  """
  def tool_call_context(parent, actor, attrs \\ %{}) do
    struct!(
      %ExecutionContext{
        owner_id: actor.id,
        chat_id: parent.chat.id,
        message_id: parent.message.id,
        assistant_message_id: parent.message.id,
        step_id: parent_step_id(parent),
        tool_call_item_id: parent_item_id(parent),
        available_file_external_ids: []
      },
      Map.new(attrs)
    )
  end

  @doc "Encodes an execution context as background tasks persist it (string keys, no nils)."
  def execution_context_json(%ExecutionContext{} = context) do
    context
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  @doc """
  Creates the durable background task of a `primitive` (`:fork` or `:spawn`)
  subagent launched by `parent` (from `create_parent_call!/4`) with `args`.
  `context_attrs` override fields of its execution context (e.g.
  `generation_fence_token`).
  """
  def create_subagent_background_task!(
        actor,
        parent,
        primitive,
        args,
        status,
        context_attrs \\ %{}
      ) do
    name = to_string(primitive)

    create!(
      BackgroundTask,
      %{
        kind: name,
        adapter: name,
        status: status,
        function_name: name,
        arguments: args,
        execution_context:
          parent |> tool_call_context(actor, context_attrs) |> execution_context_json(),
        runner_ref: %{},
        tool_instance_id: parent.tool_instance.id,
        source_chat_id: parent.chat.id,
        source_message_id: parent.message.id,
        source_step_id: parent.step_id,
        source_tool_call_item_id: parent.call.item_id,
        started_at: if(status == :running, do: DateTime.utc_now())
      },
      actor
    )
  end

  @doc """
  Persists `result` as the tool result of `call` under the generation fence of
  `lease`, as the parent writer does. Returns the `Lease.with_fence/3` result.
  """
  def persist_receipt(lease, message_id, step_id, %ToolCall{} = call, %ExecutionResult{} = result) do
    Lease.with_fence(
      lease,
      fn ->
        Persistence.persist_tool_result!(
          message_id,
          step_id,
          call,
          ToolResult.execution_payload(result)
        )
      end,
      require_generating?: true
    )
  end

  @doc "Returns the ids of chats created by the tool call item `tool_call_item_id`."
  def subchat_ids_for_call(actor, tool_call_item_id) do
    Chat
    |> Ash.Query.filter(parent_tool_call_item_id == ^tool_call_item_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.select([:id])
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  @doc """
  Returns the `:tool_result` items of `message` (loaded with `steps: [:items]`)
  that answer `tool_call_item_id`.
  """
  def tool_result_items(message, tool_call_item_id) do
    message.steps
    |> List.wrap()
    |> Enum.flat_map(&List.wrap(&1.items))
    |> Enum.filter(&(&1.type == :tool_result and &1.tool_call_item_id == tool_call_item_id))
  end

  @doc """
  Returns the opaque `"raw"` payload of the tool result answering
  `tool_call_item_id`, or `nil` (message loaded with `steps: [items: [:contents]]`).
  """
  def tool_result_raw(message, tool_call_item_id) do
    message
    |> tool_result_items(tool_call_item_id)
    |> Enum.flat_map(&List.wrap(&1.contents))
    |> Enum.find_value(fn
      %{kind: :opaque, content_json: %{"raw" => %{} = raw}} -> raw
      _other -> nil
    end)
  end

  @doc """
  Polls `BackgroundTasks.snapshot/3` until the task owned by `owner_id` reaches
  `wanted` (a status string) and returns the snapshot. Fails at once when the
  task reaches another terminal status.
  """
  def wait_for_background_snapshot!(task_id, owner_id, wanted, timeout \\ 6_000) do
    IntellectualClub.WaitHelpers.wait_until(
      fn ->
        case BackgroundTasks.snapshot(task_id, nil, owner_id) do
          {:ok, %{"status" => ^wanted} = snapshot} ->
            snapshot

          {:ok, %{"status" => status} = snapshot} when status in @terminal_statuses ->
            ExUnit.Assertions.flunk(
              "Background task reached #{status} before #{wanted}: #{inspect(snapshot)}"
            )

          {:ok, _snapshot} ->
            nil

          {:error, reason} ->
            ExUnit.Assertions.flunk("Background task snapshot failed: #{inspect(reason)}")
        end
      end,
      timeout: timeout,
      interval: 20,
      message: "Background task #{task_id} did not reach #{wanted}"
    )
  end

  defp parent_step_id(%{step_id: step_id}), do: step_id
  defp parent_step_id(%{step: %{id: step_id}}), do: step_id

  defp parent_item_id(%{call: %{item_id: item_id}}), do: item_id
  defp parent_item_id(%{item: %{id: item_id}}), do: item_id

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
