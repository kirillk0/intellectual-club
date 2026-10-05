defmodule IntellectualClub.ChatFixtures do
  @moduledoc """
  Fixtures for chats and the message tree (messages, steps, items, contents).

  All functions take the actor first (see `IntellectualClub.Fixtures` for the
  shared conventions). Chats are created with `note: ""` unless overridden.

  Chats, messages, steps, items and contents are created with
  `IntellectualClub.Fixtures.create_forcing!/4`: attributes the action does not
  accept (e.g. `:fork_task`, `:generation_fence_token`) are force-set, so tests
  can build internal states without bypassing Ash.

  Typical usage:

      chat = create_chat!(user, bot_id: bot.id)
      message = create_generating_message!(user, chat)
      step = create_step!(user, message, status: :waiting_provider)
      item = create_text_item!(user, step, "Answer")

      anchor = create_tool_call_anchor!(user)
      fork = create_linked_chat!(user, anchor, fork_task: "Investigate")
  """

  import IntellectualClub.Fixtures

  require Ash.Query

  alias IntellectualClub.Chat.{
    Chat,
    ChatMessage,
    ChatMessageContent,
    ChatMessageItem,
    ChatMessageStep,
    ChatShare,
    Threads
  }

  @doc """
  Creates a chat through `Chat`'s `:create` action, which also applies the
  default LLM configuration and the bot's first messages.

  Attributes the action does not accept (e.g. `:fork_source_step_id`,
  `:fork_task`) are force-set, see `IntellectualClub.Fixtures.create_forcing!/4`.
  """
  def create_chat!(actor, attrs \\ %{}) do
    create_forcing!(Chat, :create, merge_attrs(%{note: ""}, attrs), actor)
  end

  @doc """
  Creates a chat through `Chat`'s `:create_empty` action: no default LLM
  configuration and no first messages. Non-accepted attributes are force-set
  as in `create_chat!/2`.
  """
  def create_empty_chat!(actor, attrs \\ %{}) do
    create_forcing!(Chat, :create_empty, merge_attrs(%{note: ""}, attrs), actor)
  end

  @doc """
  Creates a subchat of `parent` (`:create_empty`) with `parent_relation_kind:
  relation_kind` (`:fork`, `:spawn`, `:handoff`) and `subagent: true`; `attrs`
  may override them or add e.g. `:parent_message_id`.
  """
  def create_subchat!(actor, parent, relation_kind, attrs \\ %{}) do
    defaults = %{
      parent_chat_id: id_of(parent),
      parent_relation_kind: relation_kind,
      subagent: true
    }

    create_empty_chat!(actor, merge_attrs(defaults, attrs))
  end

  @doc """
  Creates a linked fork chat (`:create_empty`, `subagent: true`) whose parent is
  the tool call of `anchor` (see `create_tool_call_anchor!/2`).

  Defaults: `parent_relation_kind: :fork`, `fork_source_step_id: anchor.step.id`,
  `fork_task: "Fixture fork task"`; all of them can be overridden by `attrs`.
  """
  def create_linked_chat!(
        actor,
        %{chat: chat, message: message, step: step, item: item},
        attrs \\ %{}
      ) do
    defaults = %{
      parent_chat_id: chat.id,
      parent_message_id: message.id,
      parent_tool_call_item_id: item.id,
      parent_relation_kind: :fork,
      subagent: true,
      fork_source_step_id: step.id,
      fork_task: "Fixture fork task"
    }

    create_forcing!(Chat, :create_empty, merge_attrs(defaults, attrs), actor)
  end

  @doc """
  Shares `chat` with `group`, pinning the chat's current bot and LLM configuration.
  """
  def share_chat!(actor, chat, group, attrs \\ %{}) do
    defaults = %{
      chat_id: chat.id,
      user_group_id: group.id,
      bot_id: chat.bot_id,
      llm_configuration_id: chat.llm_configuration_id
    }

    create!(ChatShare, merge_attrs(defaults, attrs), actor)
  end

  @doc """
  Inserts a message through `ChatMessage`'s low-level `:add_message` action.

  Defaults: `role: :assistant`, `status: :done`. Pass `:parent_id` to attach it
  to a branch. Use `Threads.add_message_to_end/4` when the test needs the real
  "append user input" behavior instead.
  """
  def create_message!(actor, chat, attrs \\ %{}) do
    defaults = %{chat_id: id_of(chat), role: :assistant, status: :done}
    create_forcing!(ChatMessage, :add_message, merge_attrs(defaults, attrs), actor)
  end

  @doc """
  Appends a user message to the end of `chat` (default text `"Hello"`) and
  creates a `:generating` assistant reply to it through
  `:create_generating_assistant`. Returns the assistant message.

  `attrs` go to `:create_generating_assistant` (e.g. `:llm_configuration_id`,
  `:token_count`), except for:

    * `:user_text` — text of the user message;
    * `:parent_id` — attach the reply to this message instead of adding a user
      message;
    * `:step` — when set (a step status or a map of step attributes), also
      creates step 1 of the reply.
  """
  def create_generating_message!(actor, chat, attrs \\ %{}) do
    {options, attrs} = Map.split(to_attrs(attrs), [:user_text, :parent_id, :step])

    parent_id =
      Map.get_lazy(options, :parent_id, fn ->
        text = Map.get(options, :user_text, "Hello")
        {:ok, user_message} = Threads.add_message_to_end(chat, :user, text, actor: actor)
        user_message.id
      end)

    message =
      create!(
        ChatMessage,
        :create_generating_assistant,
        merge_attrs(%{chat_id: id_of(chat), parent_id: parent_id}, attrs),
        actor
      )

    case Map.get(options, :step) do
      nil -> :ok
      status when is_atom(status) -> create_step!(actor, message, status: status)
      step_attrs -> create_step!(actor, message, step_attrs)
    end

    message
  end

  @doc """
  Creates a step of `message` (a record or an id). Defaults: `sequence: 1`,
  `status: :done`.
  """
  def create_step!(actor, message, attrs \\ %{}) do
    defaults = %{chat_message_id: id_of(message), sequence: 1, status: :done}
    create_forcing!(ChatMessageStep, :create, merge_attrs(defaults, attrs), actor)
  end

  @doc """
  Creates an item of `step` (a record or an id). Defaults: `sequence: 1`,
  `type: :answer`.
  """
  def create_item!(actor, step, attrs \\ %{}) do
    defaults = %{chat_message_step_id: id_of(step), sequence: 1, type: :answer}
    create_forcing!(ChatMessageItem, :create, merge_attrs(defaults, attrs), actor)
  end

  @doc """
  Creates a content of `item` (a record or an id). Defaults: `sequence: 1`,
  `kind: :text`.
  """
  def create_content!(actor, item, attrs \\ %{}) do
    defaults = %{chat_message_item_id: id_of(item), sequence: 1, kind: :text}
    create_forcing!(ChatMessageContent, :create, merge_attrs(defaults, attrs), actor)
  end

  @doc """
  Creates an item of `step` with a single text content and returns the item
  with `:contents` loaded. `attrs` go to the item (default `type: :answer`).
  """
  def create_text_item!(actor, step, text, attrs \\ %{}) do
    item = create_item!(actor, step, attrs)
    create_content!(actor, item, content_text: text)
    Ash.load!(item, [:contents], actor: actor)
  end

  @doc """
  Creates the parent side of a linked fork: an assistant message with step 1
  and a `:tool_call` item. Returns `%{chat: chat, message: message, step: step,
  item: item}`, which `create_linked_chat!/3` accepts.

  Options:

    * `:chat` — use this chat (default: a new `create_empty_chat!/2`);
    * `:message` — attributes for `create_message!/3` (e.g. `:parent_id`);
    * `:step` — attributes for `create_step!/3` (e.g. `response_final: true`);
    * `:item` — attributes for the tool call item;
    * `:content` — when given, attributes of a content created on the item.
  """
  def create_tool_call_anchor!(actor, opts \\ []) do
    chat = Keyword.get_lazy(opts, :chat, fn -> create_empty_chat!(actor) end)
    message = create_message!(actor, chat, Keyword.get(opts, :message, %{}))
    step = create_step!(actor, message, Keyword.get(opts, :step, %{}))
    item_attrs = merge_attrs(%{type: :tool_call}, Keyword.get(opts, :item, %{}))
    item = create_item!(actor, step, item_attrs)

    if content = Keyword.get(opts, :content) do
      create_content!(actor, item, content)
    end

    %{chat: chat, message: message, step: step, item: item}
  end

  @doc """
  Records a completed handoff on the latest step of `source_message`: a
  `:tool_call` item (sequence 1) and its `:tool_result` (sequence 2) whose opaque
  content points to `child_chat` and its `child_message` generation.
  """
  def create_handoff_result!(actor, source_message, child_chat, child_message) do
    source_message_id = id_of(source_message)

    step =
      ChatMessageStep
      |> Ash.Query.filter(chat_message_id == ^source_message_id)
      |> Ash.Query.sort(sequence: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(actor: actor)

    call_item = create_item!(actor, step, type: :tool_call)

    result_item =
      create_item!(actor, step, sequence: 2, type: :tool_result, tool_call_item_id: call_item.id)

    create_content!(actor, result_item,
      kind: :opaque,
      content_text: "",
      content_json: %{
        "raw" => %{
          "handoff" => %{"chat_id" => child_chat.id, "generation_message_id" => child_message.id}
        }
      }
    )
  end

  @doc """
  Sets the generation state of `message` through `:set_generation_state`.
  Extra `attrs` (e.g. `:finished_at`, `:error_detail`) are passed along.
  """
  def set_message_status!(actor, message, status, attrs \\ %{}) do
    message
    |> Ash.Changeset.for_update(
      :set_generation_state,
      merge_attrs(%{status: status}, attrs),
      actor: actor
    )
    |> Ash.update!(actor: actor)
  end

  @doc """
  Chat-level settings of `chat` (a record or an id), the ones copied between
  chats: `%{blocks: [{knowledge_block_id, enabled, sequence}], tools:
  [{tool_instance_id, enabled, sequence}]}` in sequence order.
  """
  def chat_binding_settings!(actor, chat) do
    %{
      blocks:
        for(
          binding <- IntellectualClub.KnowledgeFixtures.chat_block_bindings!(actor, chat),
          do: {binding.knowledge_block_id, binding.enabled, binding.sequence}
        ),
      tools:
        for(
          binding <- IntellectualClub.ToolsFixtures.chat_tool_bindings!(actor, chat),
          do: {binding.tool_instance_id, binding.enabled, binding.sequence}
        )
    }
  end

  @doc """
  Reads all messages of `chat` (a record or an id) ordered by id, with
  `steps: [items: [:contents]]` loaded.
  """
  def messages_for_chat!(actor, chat) do
    chat_id = id_of(chat)

    ChatMessage
    |> Ash.Query.filter(chat_id == ^chat_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(steps: [items: [:contents]])
    |> Ash.read!(actor: actor)
  end

  @doc "Returns the step with the lowest sequence of `message` (a record or an id)."
  def first_step!(actor, message) do
    message_id = id_of(message)

    ChatMessageStep
    |> Ash.Query.filter(chat_message_id == ^message_id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: actor)
  end

  @doc """
  Concatenates the text contents of all `:answer` items of a message loaded
  with `steps: [items: [:contents]]`, in step/item/content order.
  """
  def message_answer_text(message) do
    (Map.get(message, :steps) || [])
    |> Enum.sort_by(& &1.sequence)
    |> Enum.flat_map(&(Map.get(&1, :items) || []))
    |> Enum.filter(&(&1.type == :answer))
    |> Enum.flat_map(&(Map.get(&1, :contents) || []))
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map_join("", fn content -> content.content_text || "" end)
  end

  @doc "Concatenates the text contents of an item loaded with `:contents`."
  def item_text(item) do
    item.contents
    |> List.wrap()
    |> Enum.filter(&(&1.kind == :text))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.map_join("", &to_string(&1.content_text || ""))
  end
end
