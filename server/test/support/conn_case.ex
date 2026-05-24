defmodule IntellectualClubWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use IntellectualClubWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint IntellectualClubWeb.Endpoint

      use IntellectualClubWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import IntellectualClub.AccountsFixtures
      import IntellectualClubWeb.ConnCase
    end
  end

  setup tags do
    IntellectualClub.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Polls the BFF generation endpoint until the message reaches a terminal status.
  """
  def wait_for_generation_to_finish(conn, message_id, opts \\ [])

  def wait_for_generation_to_finish(conn, message_id, attempts_left)
      when is_integer(attempts_left) do
    wait_for_generation_to_finish(conn, message_id, attempts: attempts_left)
  end

  def wait_for_generation_to_finish(conn, message_id, opts)
      when is_integer(message_id) and is_list(opts) do
    attempts = Keyword.get(opts, :attempts, 800)
    interval_ms = Keyword.get(opts, :interval_ms, 5)

    do_wait_for_generation_to_finish(conn, message_id, attempts, interval_ms)
  end

  defp do_wait_for_generation_to_finish(_conn, _message_id, 0, _interval_ms) do
    ExUnit.Assertions.flunk("Generation did not finish within timeout")
  end

  defp do_wait_for_generation_to_finish(conn, message_id, attempts_left, interval_ms) do
    payload =
      conn
      |> Phoenix.ConnTest.dispatch(
        IntellectualClubWeb.Endpoint,
        :get,
        "/api/bff/chat-messages/#{message_id}/poll"
      )
      |> Phoenix.ConnTest.json_response(200)

    if payload["status"] in ["done", "canceled", "error"] do
      payload
    else
      Process.sleep(interval_ms)
      do_wait_for_generation_to_finish(conn, message_id, attempts_left - 1, interval_ms)
    end
  end
end
