defmodule IntellectualClub.Tools.Drivers.SshTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Tools.Drivers.Ssh
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.Executor
  alias IntellectualClub.Tools.ToolInstance

  test "exposes direct and disabled-by-default background run_command functions" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      })

    functions = Ssh.fixed_functions(tool_instance)

    run_command = Enum.find(functions, &(Map.get(&1, "name") == "run_command"))

    background =
      Enum.find(functions, &(Map.get(&1, "name") == "run_command_background"))

    assert is_map(run_command)
    assert is_map(background)
    refute Map.get(run_command, "is_background_function", false)
    assert background["is_background_function"] == true
    assert background["enabled"] == false
    assert background["enabled_by_default"] == false
    assert background["schema"] == run_command["schema"]
  end

  test "config schema marks host and username as required and orders connection fields first" do
    schema = Ssh.config_schema()
    properties = Map.fetch!(schema, "properties")

    assert schema["required"] == ["host", "username"]
    assert get_in(properties, ["host", "x-ui", "order"]) == 10
    assert get_in(properties, ["port", "x-ui", "order"]) == 20
    assert get_in(properties, ["username", "x-ui", "order"]) == 30
    assert get_in(properties, ["connect_timeout_seconds", "x-ui", "order"]) > 30
    assert get_in(properties, ["default_timeout_seconds", "x-ui", "order"]) > 30
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
    tool_instance = %ToolInstance{
      type: "ssh",
      config: %{"host" => "", "username" => "root"},
      secrets: %{"password" => "secret"}
    }

    assert {:error, "Tool instance config.host is required."} =
             Ssh.execute(tool_instance, "run_command", %{"command" => "echo ok"})
  end

  test "create validates required config fields declared by schema" do
    %{user: actor} = user_fixture()

    result =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "ssh",
          name: "SSH",
          config: %{"host" => "", "username" => ""},
          secrets: %{"password" => "secret"},
          max_output_tokens: 20_000
        },
        actor: actor
      )
      |> Ash.create()

    assert {:error, error} = result
    message = Exception.message(error)
    assert String.contains?(message, "Host is required.")
    assert String.contains?(message, "Username is required.")
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

  test "background command requires generation execution context" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      })

    assert {:error, "Background SSH command requires generation execution context."} =
             Ssh.execute(tool_instance, "run_command_background", %{"command" => "echo ok"})
  end

  test "background command is rejected by the executor while disabled by default" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor, %{
        type: "ssh",
        alias: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      })

    result =
      Executor.execute_llm_tool(
        %{"ssh" => tool_instance},
        "ssh__run_command_background",
        %{"command" => "echo should-not-run"},
        %ExecutionContext{owner_id: actor.id}
      )

    assert result.raw["isError"] == true
    assert result.raw["code"] == "tool_function_disabled"
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

  test "sftp_channel_options wraps timeout in a keyword list" do
    assert [timeout: 10_000] = Ssh.sftp_channel_options(10_000)
    assert [timeout: :infinity] = Ssh.sftp_channel_options(:infinity)
  end

  test "format_run_command_text includes timeout notice for model-visible text" do
    assert Ssh.format_run_command_text("", "", true, 1) ==
             "[timeout] Command exceeded timeout of 1 second."

    assert Ssh.format_run_command_text("partial stdout", "partial stderr", true, 2) ==
             "partial stdout\npartial stderr\n\n[timeout] Command exceeded timeout of 2 seconds."

    assert Ssh.format_run_command_text("ok\n", "", false, 1) == "ok"
  end

  test "background output collector bounds captured output while retaining byte totals" do
    stdout = String.duplicate("a", 100_000)
    stderr = String.duplicate("b", 100_000)

    assert {:ok, result} =
             Ssh.collect_background_output_for_test(
               [{:stdout, stdout}, {:stderr, stderr}, {:exit_status, 0}],
               64
             )

    assert result.stdout_bytes == byte_size(stdout)
    assert result.stderr_bytes == byte_size(stderr)
    assert result.captured_bytes == 64
    assert byte_size(result.stdout) + byte_size(result.stderr) == 64
    assert result.capture_truncated == true
  end

  test "background output collector keeps independent UTF-8 carry per stream" do
    {:ok, progress} = Agent.start_link(fn -> [] end)

    callback = fn stream, text ->
      if text != "" do
        Agent.update(progress, &[{stream, text} | &1])
      end
    end

    euro = <<0xE2, 0x82, 0xAC>>
    snowman = <<0xE2, 0x98, 0x83>>

    assert {:ok, result} =
             Ssh.collect_background_output_for_test(
               [
                 {:stdout, binary_part(euro, 0, 1)},
                 {:stderr, binary_part(snowman, 0, 1)},
                 {:stdout, binary_part(euro, 1, 2)},
                 {:stderr, binary_part(snowman, 1, 2)},
                 {:exit_status, 0}
               ],
               64,
               callback
             )

    assert result.stdout == "€"
    assert result.stderr == "☃"

    assert progress |> Agent.get(&Enum.reverse/1) == [stdout: "€", stderr: "☃"]
  end

  test "background cancel invokes the closer registered with live SSH refs" do
    task_id = Ecto.UUID.generate()
    parent = self()

    owner =
      spawn_link(fn ->
        :ok =
          Ssh.register_background_cancel_ref(
            task_id,
            :connection_ref,
            42,
            fn refs -> send(parent, {:ssh_refs_closed, refs}) end
          )

        send(parent, :cancel_ref_registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :cancel_ref_registered
    assert :ok = Ssh.cancel_background_command(task_id)

    assert_receive {:ssh_refs_closed, %{connection: :connection_ref, channel: 42}}
    send(owner, :stop)
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
