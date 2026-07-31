defmodule IntellectualClub.Llm.Auth.OpenAIOAuthCache do
  @moduledoc """
  Owns the in-memory OpenAI OAuth token cache.

  The table must outlive individual provider tasks because ETS tables are
  destroyed when their owner process exits.
  """

  use GenServer

  @table :ic_openai_oauth_token_cache

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec lookup(term()) :: [tuple()]
  def lookup(key) do
    table_operation(&:ets.lookup(&1, key))
  end

  @spec insert(tuple()) :: true
  def insert(object) when is_tuple(object) do
    table_operation(&:ets.insert(&1, object))
  end

  @spec insert_new(tuple()) :: boolean()
  def insert_new(object) when is_tuple(object) do
    table_operation(&:ets.insert_new(&1, object))
  end

  @spec delete(term()) :: true
  def delete(key) do
    table_operation(&:ets.delete(&1, key))
  end

  @doc false
  @spec clear() :: true
  def clear do
    table_operation(&:ets.delete_all_objects/1)
  end

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @impl true
  def init(_opts) do
    _table = create_table!()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    {:reply, create_table!(), state}
  end

  defp table_operation(operation, retries \\ 1) when is_function(operation, 1) do
    table = ensure_table!()
    operation.(table)
  rescue
    exception in ArgumentError ->
      if retries > 0 do
        table_operation(operation, retries - 1)
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> GenServer.call(__MODULE__, :ensure_table)
      table -> table
    end
  end

  defp create_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      table ->
        table
    end
  end
end
