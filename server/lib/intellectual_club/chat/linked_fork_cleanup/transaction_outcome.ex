defmodule IntellectualClub.Chat.LinkedForkCleanup.TransactionOutcome do
  @moduledoc """
  Private, authorized access to the outcome of an outer PostgreSQL transaction.

  A deleted row is not a commit barrier: it may have been inserted and deleted in
  the same transaction. Capture the top-level xid on the existing connection and
  observe its actual outcome from the cleanup task instead. SQL is limited to
  transaction metadata; no application entities bypass their Ash actions.
  """

  use Ash.Resource,
    domain: IntellectualClub.Chat.LinkedForkCleanup,
    authorizers: [Ash.Policy.Authorizer]

  alias IntellectualClub.Repo

  @type outcome :: :in_progress | :committed | :aborted
  @poll_interval 25

  actions do
    action :capture, :string do
      public?(false)
      transaction?(false)

      run fn _input, _context ->
        if Repo.in_transaction?() do
          case Repo.query("SELECT pg_current_xact_id()::text") do
            {:ok, %{rows: [[xid]]}} -> {:ok, xid}
            {:error, error} -> {:error, error}
          end
        else
          {:error, "Transaction outcome capture requires an existing Repo transaction"}
        end
      end
    end

    action :status, :atom do
      public?(false)
      transaction?(false)
      constraints(one_of: [:in_progress, :committed, :aborted])

      argument :xid, :string do
        allow_nil?(false)
        constraints(match: ~r/\A[0-9]{1,20}\z/)
      end

      run fn input, _context ->
        # Bind as text because Postgrex's native xid8 encoder expects an integer.
        case Repo.query("SELECT pg_xact_status($1::text::xid8)", [input.arguments.xid]) do
          {:ok, %{rows: [["in progress"]]}} -> {:ok, :in_progress}
          {:ok, %{rows: [["committed"]]}} -> {:ok, :committed}
          {:ok, %{rows: [["aborted"]]}} -> {:ok, :aborted}
          {:ok, _result} -> {:error, "PostgreSQL transaction outcome is unavailable"}
          {:error, error} -> {:error, error}
        end
      end
    end
  end

  policies do
    policy action_type(:action) do
      authorize_if actor_present()
    end
  end

  @doc "Captures the outer xid8 on the caller's existing transaction connection."
  @spec capture!(struct()) :: String.t()
  def capture!(actor) do
    __MODULE__
    |> Ash.ActionInput.for_action(:capture, %{}, actor: actor)
    |> Ash.run_action!(actor: actor, authorize?: true)
  end

  @doc "Reads the outcome without opening a transaction or locking application rows."
  @spec status(String.t(), struct()) :: {:ok, outcome()} | {:error, term()}
  def status(xid, actor) do
    __MODULE__
    |> Ash.ActionInput.for_action(:status, %{xid: xid}, actor: actor)
    |> Ash.run_action(actor: actor, authorize?: true)
  end

  @spec status!(String.t(), struct()) :: outcome()
  def status!(xid, actor) do
    __MODULE__
    |> Ash.ActionInput.for_action(:status, %{xid: xid}, actor: actor)
    |> Ash.run_action!(actor: actor, authorize?: true)
  end

  @doc "Waits outside any Repo transaction; only a confirmed commit returns true."
  @spec await_committed?(String.t(), struct()) :: boolean()
  def await_committed?(xid, actor) do
    if Repo.in_transaction?() do
      raise ArgumentError, "Transaction outcome must be awaited outside a Repo transaction"
    end

    await_outcome(xid, actor)
  end

  defp await_outcome(xid, actor) do
    case status!(xid, actor) do
      :committed ->
        true

      :aborted ->
        false

      :in_progress ->
        receive do
        after
          @poll_interval -> await_outcome(xid, actor)
        end
    end
  end
end
