defmodule IntellectualClub.Chat.ForkFixtures do
  @moduledoc """
  Builders for linked fork scenarios, on top of `IntellectualClub.ChatFixtures`.

  Import explicitly: `import IntellectualClub.Chat.ForkFixtures`.

  A *fork source* is a user root message followed by an assistant boundary
  message whose final step holds a reasoning item, an answer and one or more
  `agent__fork` tool calls (`create_fork_source!/2`). A *linked child* is a fork
  chat anchored to one of those calls (`create_fork_child!/3`).

  Corrupt states that production actions reject (cycles, broken anchors, moved
  steps) are written through the test-only `ForkHistoryCorruptFixture` and
  `ForkHistoryStepCorruptFixture` resources, which keep owner authorization.
  """

  import IntellectualClub.ChatFixtures
  import IntellectualClub.Fixtures

  alias IntellectualClub.Chat.{Chat, ChatMessage, ChatMessageStep, Threads}
  alias IntellectualClub.Chat.{ForkHistoryCorruptFixture, ForkHistoryFixtureDomain}
  alias IntellectualClub.Chat.ForkHistoryStepCorruptFixture

  @fork_task "Inspect just this branch.\nPreserve task whitespace.  "

  @doc "The default fork task (with significant whitespace)."
  def fork_task, do: @fork_task

  @doc """
  Opaque content of the `number`-th fork tool call: canonical `tool_call_id`
  and `name`, with the arguments only in the provider `raw` function call
  (`call-<number>`), so provider projections decode them from JSON.
  """
  def fork_call_payload(number \\ 1, task \\ @fork_task) do
    %{
      "tool_call_id" => "call-#{number}",
      "name" => "agent__fork",
      "raw" => %{
        "id" => "fc-#{number}",
        "type" => "function_call",
        "call_id" => "call-#{number}",
        "name" => "agent__fork",
        "arguments" => Jason.encode!(%{"task" => task})
      }
    }
  end

  @doc """
  Creates a fork source. Returns a map with `:chat`, `:root` (user message, with
  `:root_step`, `:root_item`, `:root_content`), `:message` (assistant boundary),
  `:previous` (step 1 when `previous_step?: true`, else nil), `:step` (boundary
  step), `:reasoning`, `:answer`, `:calls`, `:call` (first call) and
  `:call_content` (its opaque content). Items are loaded with `:contents`.

  Options: `:chat` (default: new `create_empty_chat!/2` with `:chat_attrs`),
  `:root_text`, `:previous_step?`, `:call_count` (default 1), `:task`, `:step`
  (extra boundary step attributes).
  """
  def create_fork_source!(actor, opts \\ []) do
    chat =
      Keyword.get_lazy(opts, :chat, fn ->
        create_empty_chat!(actor, Keyword.get(opts, :chat_attrs, %{}))
      end)

    {:ok, root} =
      Threads.add_message(chat, :user, Keyword.get(opts, :root_text, "Root question"),
        actor: actor,
        parent_id: nil
      )

    root = Ash.load!(root, [steps: [items: [:contents]]], actor: actor)
    root_step = hd(root.steps)
    root_item = hd(root_step.items)

    message =
      create_message!(actor, chat, %{
        parent_id: root.id,
        status: :generating,
        llm_configuration_id: chat.llm_configuration_id
      })

    previous =
      if Keyword.get(opts, :previous_step?, false) do
        step = create_step!(actor, message, response_final: true)
        create_text_item!(actor, step, "Earlier completed step")
        step
      end

    step_attrs = %{
      sequence: if(previous, do: 2, else: 1),
      status: :waiting_tools,
      response_final: true,
      input_tokens: 7,
      output_tokens: 3,
      raw_request: %{"model" => "test", "input" => []},
      raw_response: %{"id" => "parent-response", "output" => []}
    }

    step = create_step!(actor, message, merge_attrs(step_attrs, Keyword.get(opts, :step, %{})))
    reasoning = create_text_item!(actor, step, "Parent reasoning", sequence: 5, type: :reasoning)
    answer = create_text_item!(actor, step, "Parent completed response", sequence: 10)
    task = Keyword.get(opts, :task, @fork_task)

    calls =
      for number <- 1..Keyword.get(opts, :call_count, 1) do
        call =
          create_text_item!(actor, step, "Fork call #{number}",
            sequence: 20 + number,
            type: :tool_call
          )

        create_content!(actor, call,
          sequence: 2,
          kind: :opaque,
          content_json: fork_call_payload(number, task)
        )

        Ash.load!(call, [:contents], actor: actor)
      end

    %{
      chat: chat,
      root: root,
      root_step: root_step,
      root_item: root_item,
      root_content: hd(root_item.contents),
      message: message,
      previous: previous,
      step: step,
      reasoning: reasoning,
      answer: answer,
      calls: calls,
      call: hd(calls),
      call_content: Enum.find(hd(calls).contents, &(&1.kind == :opaque))
    }
  end

  @doc """
  Attributes linking a chat to the selected call of `source` (a fork source or
  a `create_tool_call_anchor!/2` map). Options: `:task`, `:selected_index`.
  """
  def fork_link_attrs(source, opts \\ []) do
    call =
      case source do
        %{calls: calls} -> Enum.at(calls, Keyword.get(opts, :selected_index, 0))
        %{item: item} -> item
      end

    %{
      parent_chat_id: source.chat.id,
      parent_message_id: source.message.id,
      parent_tool_call_item_id: call.id,
      parent_relation_kind: :fork,
      subagent: true,
      fork_source_step_id: source.step.id,
      fork_task: Keyword.get(opts, :task, @fork_task)
    }
  end

  @doc """
  Creates a linked child of `source` using the source chat's bot and LLM
  configuration. Options: `:task`, `:selected_index`, `:unavailable_functions`,
  `:attrs` (extra chat attributes).
  """
  def create_fork_child!(actor, source, opts \\ []) do
    attrs =
      source
      |> fork_link_attrs(opts)
      |> Map.merge(%{
        bot_id: source.chat.bot_id,
        llm_configuration_id: source.chat.llm_configuration_id
      })
      |> maybe_put(:fork_unavailable_functions, Keyword.get(opts, :unavailable_functions))
      |> merge_attrs(Keyword.get(opts, :attrs, %{}))

    create_empty_chat!(actor, attrs)
  end

  @doc """
  Creates an item of `step` with a text content (sequence 1) and an opaque
  content (sequence 2) holding `payload`; returns it with `:contents` loaded.
  `attrs` go to the item (e.g. `:sequence`, `:type`, `:tool_call_item_id`).
  """
  def create_opaque_item!(actor, step, text, payload, attrs \\ %{}) do
    item = create_text_item!(actor, step, text, attrs)
    create_content!(actor, item, sequence: 2, kind: :opaque, content_json: payload)
    Ash.load!(item, [:contents], actor: actor)
  end

  @doc """
  Creates a chain of `depth` linked forks, each anchored to a minimal source in
  the previous chat (an assistant message whose final step holds one fork
  call). Returns the chats from the plain root chat to the deepest fork
  (`depth + 1` chats).
  """
  def create_fork_chain!(actor, depth) do
    root = create_empty_chat!(actor)

    Enum.scan(1..depth, root, fn _level, chat ->
      anchor =
        create_tool_call_anchor!(actor,
          chat: chat,
          step: %{response_final: true},
          content: %{kind: :opaque, content_json: fork_call_payload()}
        )

      create_linked_chat!(actor, anchor, fork_task: @fork_task)
    end)
    |> then(&[root | &1])
  end

  @doc """
  Creates a legacy (pre-anchor) fork copy of `source`: a subagent chat pointing
  at the source chat and message, without a live anchor.
  """
  def create_legacy_fork!(actor, source, attrs \\ %{}) do
    defaults = %{
      parent_chat_id: source.chat.id,
      parent_message_id: source.message.id,
      parent_relation_kind: :fork,
      subagent: true
    }

    create_empty_chat!(actor, merge_attrs(defaults, attrs))
  end

  @doc """
  Writes anchor attributes production actions reject (e.g. a cyclic
  `parent_chat_id`) and returns the reloaded `Chat`.
  """
  def corrupt_chat!(actor, chat, attrs) do
    ForkHistoryCorruptFixture
    |> Ash.get!(id_of(chat), actor: actor, domain: ForkHistoryFixtureDomain)
    |> Ash.Changeset.for_update(:corrupt_anchor, to_attrs(attrs), actor: actor)
    |> Ash.update!(actor: actor, domain: ForkHistoryFixtureDomain)

    Ash.get!(Chat, id_of(chat), actor: actor)
  end

  @doc """
  Force-sets `attrs` on `record` through an authorized `action` (default
  `:update`); steps go through `ForkHistoryStepCorruptFixture` (`:owner_id`,
  `:chat_message_id`, `:sequence`, `:updated_at`). Returns the updated record.
  """
  def force_update!(actor, record, attrs, action \\ :update)

  def force_update!(actor, %ChatMessageStep{} = step, attrs, _action) do
    updated =
      ForkHistoryStepCorruptFixture
      |> Ash.get!(step.id, actor: actor, domain: ForkHistoryFixtureDomain)
      |> Ash.Changeset.for_update(:corrupt_identity, to_attrs(attrs), actor: actor)
      |> Ash.update!(actor: actor, domain: ForkHistoryFixtureDomain)

    Map.merge(step, Map.take(updated, [:owner_id, :chat_message_id, :sequence, :updated_at]))
  end

  def force_update!(actor, record, attrs, action) do
    record
    |> Ash.Changeset.for_update(action, %{}, actor: actor)
    |> Ash.Changeset.force_change_attributes(to_attrs(attrs))
    |> Ash.update!(actor: actor)
  end

  @doc """
  Reloads `record` and updates it through `action` (default `:update`; for
  messages use `:set_generation_state`).
  """
  def update_record!(actor, %resource{id: id}, attrs, action \\ :update) do
    resource
    |> Ash.get!(id, actor: actor)
    |> Ash.Changeset.for_update(action, to_attrs(attrs), actor: actor)
    |> Ash.update!(actor: actor)
  end

  @doc "Moves `message` under `parent_id` (which may create a cycle or a dangling path)."
  def reparent_message!(actor, %ChatMessage{} = message, parent_id),
    do: force_update!(actor, message, %{parent_id: parent_id}, :set_generation_state)

  @doc """
  Creates a fork background task whose source is the call of `source` and whose
  target is `target` (a chat or nil). Defaults: `status: :completed`.
  """
  def create_fork_task!(actor, source, target, attrs \\ %{}) do
    defaults = %{
      kind: "fork",
      adapter: "linked_fork_test",
      function_name: "fork",
      status: :completed,
      source_chat_id: source.chat.id,
      source_message_id: source.message.id,
      lifecycle_message_id: source.message.id,
      source_step_id: source.step.id,
      source_tool_call_item_id: Map.get_lazy(source, :item, fn -> source.call end).id,
      target_chat_id: target && target.id,
      runner_ref: if(target, do: %{"original_target" => target.id}, else: %{})
    }

    IntellectualClub.BackgroundTasksFixtures.create_background_task!(
      actor,
      merge_attrs(defaults, attrs)
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
