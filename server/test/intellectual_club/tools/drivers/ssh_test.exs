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

  test "download_file advertises file_id as the preferred reference" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      })

    download_file_spec =
      Enum.find(Ssh.fixed_functions(tool_instance), fn spec ->
        Map.get(spec, "name") == "download_file"
      end)

    assert is_map(download_file_spec)
    assert String.contains?(Map.get(download_file_spec, "description", ""), "`file_id`")

    schema = Map.fetch!(download_file_spec, "schema")
    properties = Map.fetch!(schema, "properties")

    assert Map.has_key?(properties, "file_id")
    refute Map.has_key?(properties, "content_id")
    assert schema["required"] == ["file_id", "local_path"]
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

  test "detect_image_mime returns detected mime type for valid image payload" do
    assert {:ok, "image/png"} = Ssh.detect_image_mime(image_payload())
  end

  test "detect_image_mime rejects invalid image payload" do
    assert {:error, "File content is not a valid image."} =
             Ssh.detect_image_mime("<html><body>404 Not Found</body></html>")
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

  defp image_payload do
    <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6,
      0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 255, 255, 63, 0,
      5, 254, 2, 254, 167, 53, 129, 132, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>
  end
end
