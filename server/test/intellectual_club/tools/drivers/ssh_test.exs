defmodule IntellectualClub.Tools.Drivers.SshTest do
  use IntellectualClub.DataCase, async: true

  alias IntellectualClub.Tools.Drivers.Ssh
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.Executor

  test "exposes direct and disabled-by-default background run_command functions" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor,
        name: "SSH",
        type: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      )

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
      create_tool_instance!(actor,
        name: "SSH",
        type: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      )

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

  test "background command requires generation execution context" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor,
        name: "SSH",
        type: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      )

    assert {:error, "Background SSH command requires generation execution context."} =
             Ssh.execute(tool_instance, "run_command_background", %{"command" => "echo ok"})
  end

  test "background command is rejected by the executor while disabled by default" do
    %{user: actor} = user_fixture()

    tool_instance =
      create_tool_instance!(actor,
        name: "SSH",
        type: "ssh",
        alias: "ssh",
        config: %{"host" => "example.com", "username" => "root"},
        secrets: %{"password" => "secret"}
      )

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
end
