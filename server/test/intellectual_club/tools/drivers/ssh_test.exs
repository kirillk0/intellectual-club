defmodule IntellectualClub.Tools.Drivers.SshTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Tools.Drivers.Ssh
  alias IntellectualClub.Tools.ToolInstance

  test "exposes fixed run_command function" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      })

    functions = Ssh.fixed_functions(tool_instance)

    assert is_list(functions)
    assert Enum.any?(functions, fn spec -> Map.get(spec, "name") == "run_command" end)
  end

  test "execute validates required host" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "ssh",
        config: %{"host" => "", "username" => "root"},
        secrets: %{"password" => "secret"}
      })

    assert {:error, "Tool instance config.host is required."} =
             Ssh.execute(tool_instance, "run_command", %{"command" => "echo ok"})
  end

  test "execute validates command arguments" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      })

    assert {:error, "Argument `command` or `argv` is required."} =
             Ssh.execute(tool_instance, "run_command", %{})
  end

  test "execute requires credentials" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{}
      })

    assert {:error, message} =
             Ssh.execute(tool_instance, "run_command", %{"command" => "echo ok"})

    assert String.contains?(String.downcase(message), "credentials")
  end

  test "execute rejects unknown function" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      })

    assert {:error, "Unknown function: unknown"} = Ssh.execute(tool_instance, "unknown", %{})
  end

  defp create_tool_instance!(actor, attrs) when is_map(attrs) do
    ToolInstance
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          type: "ssh",
          name: "SSH",
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
