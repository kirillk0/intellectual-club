defmodule IntellectualClub.Tools.LuaState do
  @moduledoc """
  Private JSON state scoped to a tool, the executing actor and a root chat.

  Only the state owner can access a row; owning a shared tool grants no access
  to another actor's state. This resource deliberately has no JSON API routes.
  """

  use IntellectualClub.Resource,
    domain: IntellectualClub.Tools,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Ownership.Changes.RequireRelatedAccessByActor
  alias IntellectualClub.Repo
  alias IntellectualClub.Tools.{ExecutionContext, ToolInstance}

  require Ash.Query

  @max_bytes 256 * 1024
  @max_depth 64
  @context_error "Lua state requires an authenticated execution context."
  @access_error "Lua state is not accessible in this execution context."
  @callback_error "Lua execution failed; state was not saved."
  @timeout_error "Lua state operation timed out; state was not saved."
  @storage_error "Lua state could not be saved."

  postgres do
    table("lua_states")
    repo(Repo)

    references do
      reference(:tool_instance, on_delete: :delete)
      reference(:owner, on_delete: :delete)
      reference(:root_chat, on_delete: :delete)
    end

    custom_indexes do
      index([:owner_id])
      index([:root_chat_id])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :state, :map do
      allow_nil?(false)
      default(%{})
      sensitive?(true)
    end

    create_timestamp(:created_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :tool_instance, ToolInstance, allow_nil?: false, attribute_type: :integer
    belongs_to :owner, User, allow_nil?: false, attribute_type: :integer
    belongs_to :root_chat, Chat, allow_nil?: false, attribute_type: :integer
  end

  identities do
    identity(:unique_execution_scope, [:tool_instance_id, :owner_id, :root_chat_id])
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)
      accept([:tool_instance_id, :root_chat_id, :state])
      change(relate_actor(:owner))

      change(
        {RequireRelatedAccessByActor,
         relationships: [:tool_instance, :root_chat], access: :readable}
      )

      change(&validate_state_change/2)
    end

    update :update do
      primary?(true)
      accept([:state])
      require_atomic?(false)
      change(&validate_state_change/2)
    end
  end

  policies do
    policy action_type([:create, :read, :update, :destroy]) do
      authorize_if(relates_to_actor_via(:owner))
    end
  end

  @doc """
  Runs `callback` once with the current JSON object, initially `%{}`.

  The callback returns `{:ok, result, new_json_state}` or `{:error, reason}`.
  Only success commits state. Callback errors, exceptions, exits and throws
  return safe messages, never the callback's raw reason or state. The host runtime
  may return `{:error, {:lua_error, message}}` for an already-sanitized diagnostic.
  There are no retries, including after lock contention or a failed commit.

  Call outside retrying transactions. Load secrets before entering this API;
  the callback must bound its external worker and must not make database calls
  from that worker while this process holds the transaction connection.

  `config :intellectual_club, IntellectualClub.Tools.LuaState` accepts positive
  `:lock_timeout_ms` (default 2,000) and `:transaction_timeout_ms` (default 15,000).
  The runtime independently bounds callback execution (normally about 10s).
  """
  @spec with_state(ToolInstance.t(), %ExecutionContext{}, (map() -> term())) ::
          {:ok, term()} | {:error, String.t()}
  def with_state(tool_instance, execution_context, callback)

  def with_state(
        %ToolInstance{id: tool_id} = tool,
        %ExecutionContext{owner_id: owner_id, chat_id: chat_id, root_chat_id: root_chat_id} =
          context,
        callback
      )
      when is_integer(tool_id) and tool_id > 0 and is_integer(owner_id) and owner_id > 0 and
             is_integer(chat_id) and chat_id > 0 and is_integer(root_chat_id) and root_chat_id > 0 and
             is_function(callback, 1) do
    actor = %User{id: owner_id}
    timeout = timeout_ms(:transaction_timeout_ms, 15_000)

    # Re-read the tool, not the supplied struct's owner or cached relationships.
    with :ok <- authorize_context(tool, context, actor, timeout) do
      Repo.transaction(
        fn ->
          with :ok <- lock_scope(tool_id, owner_id, root_chat_id, timeout),
               # Permissions may have changed while waiting for the scope lock.
               :ok <- authorize_context(tool, context, actor, timeout),
               {:ok, record} <- read_state(tool_id, owner_id, root_chat_id, actor, timeout),
               state = if(record, do: record.state, else: %{}),
               :ok <- validate_state(state),
               {:ok, result, new_state} <- invoke_callback(callback, state),
               :ok <- validate_state(new_state),
               {:ok, _record} <-
                 persist(record, tool_id, root_chat_id, new_state, actor, timeout) do
            result
          else
            {:error, message} -> Repo.rollback(message)
          end
        end,
        timeout: timeout
      )
    end
  rescue
    _exception -> {:error, @storage_error}
  catch
    :exit, _reason -> {:error, @storage_error}
  end

  def with_state(_tool_instance, _execution_context, _callback), do: {:error, @context_error}

  defp authorize_context(tool, context, actor, timeout) do
    with {:ok, %ToolInstance{} = current_tool} <-
           Ash.get(ToolInstance, tool.id, actor: actor, authorize?: true, timeout: timeout),
         :ok <- unchanged_config(tool, current_tool),
         {:ok, %Chat{}} <-
           Ash.get(Chat, context.chat_id, actor: actor, authorize?: true, timeout: timeout),
         {:ok, %Chat{}} <-
           Ash.get(Chat, context.root_chat_id, actor: actor, authorize?: true, timeout: timeout) do
      :ok
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _ -> {:error, @access_error}
    end
  end

  defp unchanged_config(tool, current_tool) do
    if tool.type == current_tool.type and tool.config == current_tool.config,
      do: :ok,
      else: {:error, "Lua tool configuration changed; call again with the current manifest."}
  end

  defp lock_scope(tool_id, owner_id, root_chat_id, timeout) do
    # A stable, namespaced 64-bit key works across nodes and also locks a scope
    # before its first row exists. All persisted data still goes through Ash.
    <<key::signed-64, _::binary>> =
      :crypto.hash(:sha256, "intellectual_club:lua_state:#{tool_id}:#{owner_id}:#{root_chat_id}")

    lock_timeout = "#{timeout_ms(:lock_timeout_ms, 2_000)}ms"

    with {:ok, _} <-
           Repo.query("SELECT set_config('lock_timeout', $1, true)", [lock_timeout],
             timeout: timeout
           ),
         {:ok, _} <-
           Repo.query("SELECT pg_advisory_xact_lock($1)", [key], timeout: timeout) do
      :ok
    else
      {:error, %Postgrex.Error{postgres: %{code: code}}}
      when code in [:lock_not_available, :query_canceled] ->
        {:error, @timeout_error}

      _ ->
        {:error, @storage_error}
    end
  end

  defp read_state(tool_id, owner_id, root_chat_id, actor, timeout) do
    __MODULE__
    |> Ash.Query.filter(
      tool_instance_id == ^tool_id and owner_id == ^owner_id and root_chat_id == ^root_chat_id
    )
    |> Ash.read_one(actor: actor, authorize?: true, timeout: timeout)
    |> storage_result()
  end

  defp persist(nil, tool_id, root_chat_id, state, actor, timeout) do
    __MODULE__
    |> Ash.Changeset.for_create(
      :create,
      %{tool_instance_id: tool_id, root_chat_id: root_chat_id, state: state},
      actor: actor
    )
    |> Ash.create(actor: actor, authorize?: true, timeout: timeout)
    |> storage_result()
  end

  defp persist(record, _tool_id, _root_chat_id, state, actor, timeout) do
    record
    |> Ash.Changeset.for_update(:update, %{state: state}, actor: actor)
    |> Ash.update(actor: actor, authorize?: true, timeout: timeout)
    |> storage_result()
  end

  defp storage_result({:ok, record}), do: {:ok, record}
  defp storage_result({:error, _error}), do: {:error, @storage_error}

  defp invoke_callback(callback, state) do
    case callback.(state) do
      {:ok, result, new_state} ->
        {:ok, result, new_state}

      {:error, :timeout} ->
        {:error, @timeout_error}

      {:error, {:lua_error, message}} when is_binary(message) ->
        if String.valid?(message),
          do: {:error, String.slice(message, 0, 4_096)},
          else: {:error, @callback_error}

      _ ->
        {:error, @callback_error}
    end
  rescue
    _exception -> {:error, @callback_error}
  catch
    :exit, :timeout -> {:error, @timeout_error}
    :exit, {:timeout, _details} -> {:error, @timeout_error}
    _kind, _reason -> {:error, @callback_error}
  end

  defp timeout_ms(key, default) do
    case Application.get_env(:intellectual_club, __MODULE__, []) |> Keyword.get(key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp validate_state_change(changeset, _context) do
    case validate_state(Ash.Changeset.get_attribute(changeset, :state)) do
      :ok -> changeset
      {:error, message} -> Ash.Changeset.add_error(changeset, field: :state, message: message)
    end
  end

  defp validate_state(state) when is_map(state) and not is_struct(state) do
    case json_budget(state, 0, @max_bytes) do
      {:ok, _remaining} -> :ok
      {:error, :size} -> {:error, "Lua state exceeds the 256 KiB JSON limit."}
      {:error, :depth} -> {:error, "Lua state exceeds the maximum JSON depth of 64."}
      {:error, :json} -> {:error, "Lua state must be a JSON object with string keys."}
    end
  end

  defp validate_state(_state), do: {:error, "Lua state must be a JSON object with string keys."}

  # Count the exact encoded size while traversing, stopping at the first limit
  # rather than constructing one potentially enormous encoded object.
  defp json_budget(_value, _depth, remaining) when remaining < 0, do: {:error, :size}
  defp json_budget(_value, depth, _remaining) when depth > @max_depth, do: {:error, :depth}

  defp json_budget(value, depth, remaining) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, budget(remaining - 2), fn
      {key, item}, {:ok, left} when is_binary(key) ->
        with {:ok, left} <- json_budget(key, depth + 1, left),
             {:ok, left} <- json_budget(item, depth + 1, left - 1) do
          {:cont, {:ok, left - 1}}
        else
          error -> {:halt, error}
        end

      _entry, {:ok, _left} ->
        {:halt, {:error, :json}}

      _entry, error ->
        {:halt, error}
    end)
    |> finish_container(map_size(value))
  end

  defp json_budget(value, depth, remaining) when is_list(value) do
    Enum.reduce_while(value, budget(remaining - 2), fn
      item, {:ok, left} ->
        case json_budget(item, depth + 1, left) do
          {:ok, left} -> {:cont, {:ok, left - 1}}
          error -> {:halt, error}
        end

      _item, error ->
        {:halt, error}
    end)
    |> finish_container(if(value == [], do: 0, else: 1))
  end

  defp json_budget(value, _depth, remaining)
       when is_binary(value) and byte_size(value) > remaining,
       do: {:error, :size}

  defp json_budget(value, _depth, remaining)
       when is_binary(value) or is_number(value) or value in [nil, true, false] do
    case Jason.encode_to_iodata(value) do
      {:ok, encoded} -> budget(remaining - IO.iodata_length(encoded))
      {:error, _error} -> {:error, :json}
    end
  end

  defp json_budget(_value, _depth, _remaining), do: {:error, :json}

  # Non-empty containers have one fewer comma than entries.
  defp finish_container({:ok, left}, count), do: budget(left + if(count > 0, do: 1, else: 0))
  defp finish_container(error, _count), do: error

  defp budget(remaining) when remaining >= 0, do: {:ok, remaining}
  defp budget(_remaining), do: {:error, :size}
end
