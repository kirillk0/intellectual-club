defmodule IntellectualClub.RepoTest do
  use IntellectualClub.DataCase, async: true

  import ExUnit.CaptureLog

  describe "after_commit/1" do
    test "work runs immediately outside a transaction" do
      assert :ok = Repo.after_commit(fn -> send(self(), :outside) end)
      assert_received :outside
    end

    test "nested transactions preserve registration order and release the connection first" do
      assert {:ok, :outer} =
               Repo.transaction(fn ->
                 Repo.after_commit(fn -> send(self(), {:first, Repo.in_transaction?()}) end)

                 assert {:ok, :inner} =
                          Repo.transact(fn ->
                            Repo.after_commit(fn -> send(self(), :second) end)
                            {:ok, :inner}
                          end)

                 refute_received {:first, _}
                 refute_received :second
                 :outer
               end)

      assert_received {:first, false}
      assert_received :second
    end

    test "error returns and failed multi operations discard work" do
      assert {:error, :aborted} =
               Repo.transact(fn ->
                 Repo.after_commit(fn -> send(self(), :discarded) end)
                 {:error, :aborted}
               end)

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:register, fn _repo, _changes ->
          Repo.after_commit(fn -> send(self(), :discarded) end)
          {:ok, :registered}
        end)
        |> Ecto.Multi.run(:abort, fn _repo, _changes -> {:error, :aborted} end)

      assert {:error, :abort, :aborted, %{register: :registered}} = Repo.transaction(multi)
      assert {:ok, :later} = Repo.transaction(fn -> :later end)
      refute_received :discarded
    end

    test "a handled nested rollback still discards every callback of the outer transaction" do
      assert {:error, :rollback} =
               Repo.transaction(fn ->
                 Repo.after_commit(fn -> send(self(), :discarded) end)

                 assert {:error, :nested_abort} =
                          Repo.transaction(fn ->
                            Repo.after_commit(fn -> send(self(), :discarded) end)
                            Repo.rollback(:nested_abort)
                          end)

                 :attempted_commit
               end)

      assert {:ok, :later} = Repo.transaction(fn -> :later end)
      refute_received :discarded
    end

    test "raise and throw clear the queue before the next transaction" do
      assert_raise RuntimeError, "abort", fn ->
        Repo.transaction(fn ->
          Repo.after_commit(fn -> send(self(), :discarded) end)
          raise "abort"
        end)
      end

      assert catch_throw(
               Repo.transaction(fn ->
                 Repo.after_commit(fn -> send(self(), :discarded) end)
                 throw(:aborted)
               end)
             ) == :aborted

      assert {:ok, :later} = Repo.transaction(fn -> :later end)
      refute_received :discarded
    end

    test "failing and reentrant callbacks cannot change the commit result or lose later work" do
      log =
        capture_log(fn ->
          assert {:ok, :committed} =
                   Repo.transaction(fn ->
                     Repo.after_commit(fn -> raise "callback failure" end)
                     Repo.after_commit(fn -> throw(:callback_throw) end)

                     Repo.after_commit(fn ->
                       Repo.transaction(fn ->
                         Repo.after_commit(fn -> send(self(), :reentrant) end)
                       end)
                     end)

                     Repo.after_commit(fn -> send(self(), :last) end)
                     :committed
                   end)
        end)

      assert log =~ "callback failure"
      assert log =~ "callback_throw"
      assert_received :reentrant
      assert_received :last
    end

    test "callbacks use their registering repo and restore the caller's dynamic repo" do
      original = Repo.get_dynamic_repo()
      other = :unavailable_after_commit_test_repo

      try do
        assert {:ok, :committed} =
                 Repo.transaction(fn ->
                   Repo.after_commit(fn ->
                     send(self(), {:first_repo, Repo.get_dynamic_repo()})
                     Repo.put_dynamic_repo(other)
                   end)

                   Repo.after_commit(fn ->
                     send(self(), {:second_repo, Repo.get_dynamic_repo()})
                   end)

                   Repo.put_dynamic_repo(other)
                   :committed
                 end)

        assert_received {:first_repo, ^original}
        assert_received {:second_repo, ^original}
        assert Repo.get_dynamic_repo() == other
      after
        Repo.put_dynamic_repo(original)
      end
    end
  end

  describe "with_statement_timeout/2" do
    test "returns the result and restores the enclosing transaction's settings" do
      before = Repo.query!("SELECT current_setting('statement_timeout'), current_setting('jit')")

      assert {:ok, ["5s", "off"]} =
               Repo.with_statement_timeout(5_000, fn ->
                 Repo.query!(
                   "SELECT current_setting('statement_timeout'), current_setting('jit')"
                 ).rows
                 |> hd()
               end)

      assert Repo.query!("SELECT current_setting('statement_timeout'), current_setting('jit')").rows ==
               before.rows
    end

    test "cancels a statement that runs past the timeout and keeps the connection usable" do
      before = Repo.query!("SELECT current_setting('statement_timeout')").rows

      assert {:error, :statement_timeout} =
               Repo.with_statement_timeout(10, fn -> Repo.query!("SELECT pg_sleep(5)") end)

      assert Repo.query!("SELECT current_setting('statement_timeout')").rows == before
      assert %{rows: [[1]]} = Repo.query!("SELECT 1")
    end

    test "remembers cancellation even when an optional loader handles the original error" do
      assert {:error, :statement_timeout} =
               Repo.with_statement_timeout(10, fn ->
                 assert {:error, _} = Repo.query("SELECT pg_sleep(1)")
                 Repo.query!("SELECT 1")
               end)

      assert %{rows: [[1]]} = Repo.query!("SELECT 1")
      assert {:ok, :next} = Repo.with_statement_timeout(1_000, fn -> :next end)
    end

    test "does not classify a handled non-timeout SQL error as cancellation" do
      assert_raise Postgrex.Error, ~r/in_failed_sql_transaction/, fn ->
        Repo.with_statement_timeout(1_000, fn ->
          assert {:error, _} = Repo.query("SELECT 1 / 0")
          Repo.query!("SELECT 1")
        end)
      end
    end

    test "re-raises errors other than statement cancellation" do
      assert_raise Postgrex.Error, ~r/division_by_zero/, fn ->
        Repo.with_statement_timeout(5_000, fn -> Repo.query!("SELECT 1 / 0") end)
      end
    end
  end
end
