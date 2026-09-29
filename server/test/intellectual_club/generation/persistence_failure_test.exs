defmodule IntellectualClub.Generation.PersistenceFailureTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Generation.PersistenceFailure, as: Failure

  test "explicitly idempotent cleanup retries a lost acknowledgement without replaying an effect" do
    Process.put(:cleanup_attempts, 0)
    Process.put(:fence, "old-owner")

    assert :ok =
             Failure.retry_idempotent(
               fn ->
                 attempt = Process.get(:cleanup_attempts) + 1
                 Process.put(:cleanup_attempts, attempt)

                 if Process.get(:fence) == "old-owner", do: Process.put(:fence, nil)

                 if attempt == 1 do
                   raise DBConnection.ConnectionError, message: "commit acknowledgement lost"
                 end

                 :ok
               end,
               operation: :generation_lease_cleanup,
               delays: [0]
             )

    assert Process.get(:cleanup_attempts) == 2
    assert Process.get(:fence) == nil
  end

  test "idempotent retry is bounded and never retries an unrelated permanent error" do
    error = %DBConnection.ConnectionError{reason: :queue_timeout, message: "pool busy"}
    Process.put(:cleanup_attempts, 0)

    assert {:error, ^error} =
             Failure.retry_idempotent(
               fn ->
                 Process.put(:cleanup_attempts, Process.get(:cleanup_attempts) + 1)
                 {:error, error}
               end,
               operation: :generation_lease_cleanup,
               delays: [0, 0, 0, 0]
             )

    assert Process.get(:cleanup_attempts) == 4

    assert {:error, :forbidden} =
             Failure.retry_idempotent(
               fn ->
                 Process.put(:cleanup_attempts, Process.get(:cleanup_attempts) + 1)
                 {:error, :forbidden}
               end,
               operation: :generation_lease_cleanup,
               delays: [0, 0, 0]
             )

    assert Process.get(:cleanup_attempts) == 5
  end

  test "database observation failure uses typed causes rather than error text" do
    error = %DBConnection.ConnectionError{reason: :queue_timeout, message: "pool busy"}
    assert Failure.transient_database_error?(Failure.new(error))
    refute Failure.transient_database_error?("DBConnection.ConnectionError queue_timeout")
    refute Failure.transient_database_error?(:not_found)
    refute Failure.transient_database_error?(%Ash.Error.Forbidden{})
  end

  test "only typed rollback errors are eligible for transaction replay" do
    for code <- [:deadlock_detected, :serialization_failure, "40P01", "40001"] do
      error = %Postgrex.Error{postgres: %{code: code}}
      assert Failure.rollback?(error)

      assert Failure.rollback?(%Ash.Error.Unknown{
               errors: [%Ash.Error.Unknown.UnknownError{error: error}]
             })
    end

    refute Failure.rollback?("deadlock_detected 40P01")
    refute Failure.rollback?(%ArgumentError{message: "40001"})
    refute Failure.rollback?(%Postgrex.Error{postgres: %{code: :check_violation}})
    refute Failure.rollback?(%DBConnection.ConnectionError{message: "connection dropped"})
  end

  test "transaction replay is bounded and preserves the original typed cause" do
    Process.put(:attempts, 0)
    error = %Postgrex.Error{postgres: %{code: :deadlock_detected}}

    failure =
      assert_raise Failure, fn ->
        Failure.transaction(
          fn ->
            Process.put(:attempts, Process.get(:attempts) + 1)
            raise error
          end,
          delays: [0, 0, 0, 0, 0],
          operation: :test
        )
      end

    assert Process.get(:attempts) == 4
    assert failure.kind == :retry_exhausted
    assert failure.attempts == 4
    assert failure.reason == error
  end

  test "successful retry returns its original result once" do
    Process.put(:attempts, 0)

    assert {:ok, :committed} =
             Failure.transaction(
               fn ->
                 attempt = Process.get(:attempts) + 1
                 Process.put(:attempts, attempt)

                 if attempt == 1,
                   do: raise(%Postgrex.Error{postgres: %{code: :serialization_failure}})

                 {:ok, :committed}
               end,
               delays: [0]
             )

    assert Process.get(:attempts) == 2
  end

  test "connection failure with possible commit is never replayed" do
    Process.put(:effects, 0)

    assert {:error, failure} =
             Failure.capture(
               fn ->
                 Failure.transaction(
                   fn ->
                     Process.put(:effects, Process.get(:effects) + 1)

                     raise DBConnection.ConnectionError,
                       message: "commit acknowledgment unavailable"
                   end,
                   delays: [0, 0, 0]
                 )
               end,
               :done
             )

    assert failure.kind == :unknown
    assert Process.get(:effects) == 1
  end

  test "lost acknowledgement differs from an ordinary error and a lost lease" do
    assert Failure.new(%ArgumentError{message: "invalid request"}).kind == :permanent
    assert Failure.task_down(:killed, :provider_completed).kind == :unknown
    assert Failure.task_down({:generation_lease_lost, :lease_lost}, :done).kind == :lease_lost
    assert Failure.new(:lease_lost).kind == :lease_lost
    assert {:error, %{kind: :unknown}} = Failure.capture(fn -> exit(:timeout) end, :done)
  end

  test "read-side driver errors survive Ash wrapping without leaking into another operation" do
    error = %DBConnection.ConnectionError{message: "connection unavailable"}

    assert {:error, failure} =
             Failure.capture(
               fn ->
                 :telemetry.execute([:intellectual_club, :repo, :query], %{}, %{
                   result: {:error, error}
                 })

                 {:error,
                  %Ash.Error.Unknown{
                    errors: [%Ash.Error.Unknown.UnknownError{error: "opaque driver failure"}]
                  }}
               end,
               :queued_steers
             )

    assert failure.kind == :unknown
    assert failure.reason == error

    assert {:error, %{kind: :permanent, reason: %ArgumentError{}}} =
             Failure.capture(
               fn -> raise ArgumentError, "unrelated invalid data" end,
               :tool_followup
             )
  end

  test "an unexpected exception at a composite boundary has an unknown commit outcome" do
    assert {:error, %{kind: :unknown}} =
             Failure.capture(
               fn -> raise ArgumentError, "after a possible commit" end,
               :transition,
               unknown_exception?: true
             )
  end

  test "UI summaries do not include raw arguments or SQL payloads" do
    error = %ArgumentError{message: "secret payload"}
    text = Failure.new(error, operation: :tool_followup) |> Failure.summary()
    assert text =~ "tool_followup"
    assert text =~ "ArgumentError"
    refute text =~ "secret payload"
  end
end
