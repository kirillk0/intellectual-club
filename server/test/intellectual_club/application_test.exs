defmodule IntellectualClub.ApplicationTest do
  use ExUnit.Case, async: true

  import IntellectualClub.TestHttpServer
  import Plug.Conn

  describe "start/2" do
    test "loads every application module, so callback checks see all implementations" do
      {:ok, modules} = :application.get_key(:intellectual_club, :modules)

      assert Enum.reject(modules, &:erlang.module_loaded/1) == []
    end
  end

  describe "HTTP pools" do
    test "keep more than fifty streams open with default and custom connection timeouts" do
      test_pid = self()
      supervisor = start_supervised!(Task.Supervisor)

      for options <- [[], [finch: IntellectualClub.HttpClient.finch_options(1_234)]] do
        {url, _port} =
          start_http_server!(fn conn, _opts ->
            conn = send_chunked(conn, 200)
            {:ok, conn} = chunk(conn, "ready")
            send(test_pid, {:stream_open, self()})

            receive do
              :finish -> conn
            end
          end)

        tasks =
          for _ <- 1..51 do
            Task.Supervisor.async(supervisor, fn ->
              response = Req.get!(url, [into: :self, retry: false] ++ options)
              assert response.status == 200
              assert response.body |> Enum.to_list() |> IO.iodata_to_binary() == "ready"
            end)
          end

        connections =
          for _ <- tasks do
            assert_receive {:stream_open, connection}, 5_000
            connection
          end

        Enum.each(connections, &send(&1, :finish))
        Task.await_many(tasks, 5_000)
      end
    end
  end
end
