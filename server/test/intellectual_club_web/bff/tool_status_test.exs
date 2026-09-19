defmodule IntellectualClubWeb.Bff.ToolStatusTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.{ToolInstance, ToolInstanceShare}

  setup do
    Runtime.reset!()
    on_exit(fn -> Runtime.reset!() end)
    :ok
  end

  test "returns only requested accessible outlet statuses and reflects presence changes", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()
    %{user: other} = user_fixture()
    online = create_tool!(actor)
    offline = create_tool!(actor)
    _unrequested = create_tool!(actor)
    private = create_tool!(other)
    other_type = create_tool!(actor, "native-web-search")

    assert {:ok, _} =
             Runtime.poll(online, %{
               "runner_id" => "status-runner",
               "capacity" => 0,
               "max_wait_seconds" => 0
             })

    conn = sign_in_conn(conn, actor.username, password)

    path =
      "/api/bff/tools/status?ids=#{online.id},#{offline.id},#{private.id},#{other_type.id},#{online.id}"

    response = get(conn, path)
    assert get_resp_header(response, "cache-control") == ["no-store"]

    assert Enum.sort_by(json_response(response, 200)["tools"], & &1["id"]) == [
             %{"id" => online.id, "outlet_online" => true},
             %{"id" => offline.id, "outlet_online" => false}
           ]

    :sys.replace_state(Runtime, fn state ->
      update_in(state, [:instances, online.id, :runner, :last_seen_ms], &(&1 - 61_000))
    end)

    response = conn |> get(path) |> json_response(200)
    assert Enum.all?(response["tools"], &(&1["outlet_online"] == false))
  end

  test "honors direct sharing and revocation", %{conn: conn} do
    %{user: owner} = user_fixture()
    %{user: recipient, password: password} = user_fixture()
    %{group: group} = user_group_fixture(%{users: [owner, recipient]})
    tool = create_tool!(owner)

    share =
      ToolInstanceShare
      |> Ash.Changeset.for_create(:create, %{tool_instance_id: tool.id, user_group_id: group.id},
        actor: owner
      )
      |> Ash.create!(actor: owner)

    conn = sign_in_conn(conn, recipient.username, password)
    path = "/api/bff/tools/status?ids=#{tool.id}"

    assert conn |> get(path) |> json_response(200) == %{
             "tools" => [%{"id" => tool.id, "outlet_online" => false}]
           }

    Ash.destroy!(share, actor: owner)
    assert conn |> get(path) |> json_response(200) == %{"tools" => []}
  end

  test "requires authentication and validates bounded positive IDs", %{conn: conn} do
    assert conn |> get("/api/bff/tools/status?ids=1") |> json_response(401)
    %{user: actor, password: password} = user_fixture()
    conn = sign_in_conn(conn, actor.username, password)

    for ids <- [
          nil,
          "",
          "0",
          "-1",
          "1,invalid",
          "1,",
          "9223372036854775808",
          Enum.join(1..201, ","),
          ["1"]
        ] do
      response =
        get(conn, "/api/bff/tools/status", if(is_nil(ids), do: %{}, else: %{"ids" => ids}))

      assert json_response(response, 422)["error"] =~ "ids must contain"
    end
  end

  defp create_tool!(actor, type \\ "outlet") do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      %{type: type, name: "Status test #{System.unique_integer([:positive])}", config: %{}},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
