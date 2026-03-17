defmodule IntellectualClub.Tools.Drivers.OutletTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Outlets.Runtime
  alias IntellectualClub.Tools.Drivers.Outlet
  alias IntellectualClub.Tools.ToolInstance

  test "discover accepts execution result payload returned by outlet runtime" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "outlet",
        name: "Shell2 outlet",
        config: %{},
        secrets: %{"token" => "runner-token"}
      })

    runner_payload = %{
      "runner_id" => "runner-discovery",
      "runner_session_id" => "runner-discovery",
      "capacity" => 1,
      "max_wait_seconds" => 0
    }

    assert {:ok, %{status: "idle", tasks: []}} = Runtime.poll(tool_instance, runner_payload)

    discover_task = Task.async(fn -> Outlet.discover(tool_instance) end)

    task =
      wait_for_task(tool_instance, runner_payload, fn task ->
        Map.get(task, :function, Map.get(task, "function")) == "outlet.list_tools"
      end)

    assert :ok =
             Runtime.complete(tool_instance, %{
               "call_id" => Map.get(task, :call_id, Map.get(task, "call_id")),
               "runner_id" => "runner-discovery",
               "runner_session_id" => "runner-discovery",
               "status" => "done",
               "result_text" => "{\"tools\":[]}",
               "result_raw" => %{
                 "tools" => [
                   %{
                     "name" => "read_image",
                     "description" => "Read an image file.",
                     "input_schema" => %{
                       "type" => "object",
                       "properties" => %{
                         "local_path" => %{"type" => "string"}
                       },
                       "required" => ["local_path"],
                       "additionalProperties" => false
                     }
                   }
                 ]
               },
               "result_media" => [],
               "result_artifacts" => []
             })

    assert {:ok,
            [
              %{
                "name" => "read_image",
                "description" => "Read an image file.",
                "schema" => %{
                  "type" => "object",
                  "description" => "Read an image file.",
                  "properties" => %{"local_path" => %{"type" => "string"}},
                  "required" => ["local_path"],
                  "additionalProperties" => false
                }
              }
            ]} = Task.await(discover_task, 5_000)
  end

  defp wait_for_task(tool_instance, runner_payload, predicate, attempts \\ 20)

  defp wait_for_task(_tool_instance, _runner_payload, _predicate, 0) do
    flunk("Timed out waiting for outlet discovery task")
  end

  defp wait_for_task(tool_instance, runner_payload, predicate, attempts) do
    case Runtime.poll(tool_instance, runner_payload) do
      {:ok, %{tasks: tasks}} ->
        case Enum.find(tasks, predicate) do
          nil ->
            Process.sleep(25)
            wait_for_task(tool_instance, runner_payload, predicate, attempts - 1)

          task ->
            task
        end

      other ->
        flunk("Unexpected poll result: #{inspect(other)}")
    end
  end

  defp create_tool_instance!(actor, attrs) when is_map(attrs) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          type: "outlet",
          name: "Outlet",
          config: %{},
          secrets: %{},
          max_output_tokens: 20_000
        },
        attrs
      ),
      actor: actor
    )
    |> Ash.create!()
  end
end
