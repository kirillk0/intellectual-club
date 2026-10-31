defmodule IntellectualClub.Chat.SearchDeadline do
  @moduledoc "A cancellable end-to-end budget, including SQL and response enrichment."
  alias IntellectualClub.Repo
  @key {__MODULE__, :deadline}

  def run(fun) when is_function(fun, 0) do
    if Process.get(@key) do
      protect(fun)
    else
      timeout = Application.get_env(:intellectual_club, :chat_search_timeout_ms, 5_000)
      repo = Repo.get_dynamic_repo()
      locale = Gettext.get_locale()

      task =
        Task.async(fn ->
          Repo.put_dynamic_repo(repo)
          Gettext.put_locale(locale)
          Process.put(@key, System.monotonic_time(:millisecond) + timeout)

          try do
            {:result, protect(fun)}
          rescue
            error -> {:exception, error, __STACKTRACE__}
          end
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:result, result}} -> result
        {:ok, {:exception, error, stack}} -> reraise(error, stack)
        nil -> {:error, :timeout}
        {:exit, reason} -> exit(reason)
      end
    end
  end

  def query(fun) do
    timeout =
      min(
        remaining(),
        Application.get_env(:intellectual_club, :chat_search_statement_timeout_ms, 5_000)
      )

    case Repo.with_statement_timeout(timeout, fun) do
      {:ok, result} -> result
      {:error, :statement_timeout} -> throw(:chat_search_timeout)
    end
  end

  def probe(fun) do
    timeout =
      min(
        remaining(),
        Application.get_env(:intellectual_club, :chat_search_probe_timeout_ms, 250)
      )

    if timeout <= 0,
      do: {:error, :statement_timeout},
      else: Repo.with_statement_timeout(timeout, fun)
  end

  defp remaining do
    deadline = Process.get(@key, System.monotonic_time(:millisecond) + 5_000)
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: throw(:chat_search_timeout), else: remaining
  end

  defp protect(fun) do
    case fun.() do
      {:error, reason} when reason in [:timeout, :invalid_cursor] -> {:error, reason}
      result -> {:ok, result}
    end
  catch
    :throw, :chat_search_timeout -> {:error, :timeout}
    :throw, :invalid_search_cursor -> {:error, :invalid_cursor}
  end
end
