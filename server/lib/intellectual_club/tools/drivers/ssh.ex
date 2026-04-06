defmodule IntellectualClub.Tools.Drivers.Ssh do
  @moduledoc """
  Native SSH driver.

  Exposes a fixed `run_command` function that executes commands on a remote host.
  """

  @behaviour IntellectualClub.Tools.Driver
  @compile {:no_warn_undefined,
            [
              {:ssh, :connect, 4},
              {:ssh, :close, 1},
              {:ssh_sftp, :start_channel, 2},
              {:ssh_sftp, :stop_channel, 1},
              {:ssh_sftp, :read_file, 2},
              {:ssh_sftp, :write_file, 3},
              {:ssh_connection, :session_channel, 2},
              {:ssh_connection, :exec, 4},
              {:ssh_connection, :send, 3},
              {:ssh_connection, :send_eof, 2},
              {:ssh_connection, :close, 2}
            ]}

  alias IntellectualClub.Chat.ContentFiles
  alias IntellectualClub.Files
  alias IntellectualClub.Tools.Drivers.SshKeyCb
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  @default_port 22
  @default_connect_timeout_seconds 10
  @default_timeout_seconds 60
  @env_key_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @impl true
  def type, do: "ssh"

  @impl true
  def title, do: "SSH"

  @impl true
  def description, do: "Execute remote commands on an SSH host."

  @impl true
  def functions_mode, do: :fixed

  @impl true
  def supports_discovery?, do: false

  @impl true
  def default_config do
    %{
      "host" => "",
      "port" => @default_port,
      "username" => "",
      "connect_timeout_seconds" => @default_connect_timeout_seconds,
      "default_timeout_seconds" => @default_timeout_seconds
    }
  end

  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{
        "host" => %{
          "type" => "string",
          "title" => "Host",
          "description" => "SSH host or IP address.",
          "x-ui" => %{"placeholder" => "example.com"}
        },
        "port" => %{
          "type" => "integer",
          "title" => "Port",
          "description" => "SSH port.",
          "minimum" => 1
        },
        "username" => %{
          "type" => "string",
          "title" => "Username",
          "description" => "SSH username.",
          "x-ui" => %{"placeholder" => "root"}
        },
        "connect_timeout_seconds" => %{
          "type" => "integer",
          "title" => "Connect timeout (seconds)",
          "description" => "Connection/handshake timeout in seconds.",
          "minimum" => 0
        },
        "default_timeout_seconds" => %{
          "type" => "integer",
          "title" => "Default command timeout (seconds)",
          "description" => "Default command timeout in seconds when argument is omitted.",
          "minimum" => 0
        }
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def secrets_schema do
    %{
      "type" => "object",
      "properties" => %{
        "password" => %{
          "type" => "string",
          "title" => "Password",
          "description" => "SSH password."
        },
        "private_key" => %{
          "type" => "string",
          "title" => "Private key",
          "description" => "SSH private key in PEM/OpenSSH text format.",
          "x-ui" => %{
            "widget" => "textarea",
            "placeholder" => "-----BEGIN OPENSSH PRIVATE KEY-----"
          }
        }
      }
    }
  end

  @impl true
  def fixed_functions(%ToolInstance{} = _tool_instance) do
    [
      %{
        "name" => "run_command",
        "description" =>
          "Run a shell command on the SSH host and return stdout/stderr. If `argv` is provided, it takes precedence.",
        "schema" => %{
          "type" => "object",
          "description" =>
            "Provide either `command` (shell string) or `argv` (array of strings). If both are set, `argv` takes precedence.",
          "properties" => %{
            "command" => %{
              "type" => "string",
              "description" => "Shell command to execute."
            },
            "argv" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Command argv to execute via shell escaping (argv[0] is program)."
            },
            "cwd" => %{
              "type" => "string",
              "description" => "Working directory (optional)."
            },
            "env" => %{
              "type" => "object",
              "description" => "Environment variables (optional).",
              "additionalProperties" => %{"type" => "string"}
            },
            "stdin" => %{
              "type" => "string",
              "description" => "Standard input (optional)."
            },
            "timeout_seconds" => %{
              "type" => "integer",
              "description" => "Command timeout in seconds (optional). 0 means no timeout.",
              "minimum" => 0
            }
          },
          "additionalProperties" => false
        },
        "enabled" => true
      },
      %{
        "name" => "read_image",
        "description" => "Read an image file from the remote host and attach it as media.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "local_path" => %{
              "type" => "string",
              "description" => "Remote path to the image file."
            }
          },
          "required" => ["local_path"],
          "additionalProperties" => false
        },
        "enabled" => true
      },
      %{
        "name" => "download_file",
        "description" => "Download a chat file into the remote filesystem using `file_id`.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "file_id" => %{
              "type" => "string",
              "description" =>
                "File external UUID returned by `upload_file` or artifact metadata."
            },
            "local_path" => %{"type" => "string", "description" => "Remote destination path."}
          },
          "required" => ["file_id", "local_path"],
          "additionalProperties" => false
        },
        "enabled" => true
      },
      %{
        "name" => "upload_file",
        "description" => "Upload a remote file as a user-visible artifact.",
        "schema" => %{
          "type" => "object",
          "properties" => %{
            "local_path" => %{"type" => "string", "description" => "Remote source path."}
          },
          "required" => ["local_path"],
          "additionalProperties" => false
        },
        "enabled" => true
      }
    ]
  end

  @impl true
  def discover(%ToolInstance{} = _tool_instance) do
    {:error, "Discovery is not supported for this tool type."}
  end

  @impl true
  def execute(%ToolInstance{} = tool_instance, function_name, args, execution_context \\ nil)
      when is_binary(function_name) and is_map(args) do
    case function_name do
      "run_command" -> run_command(tool_instance, args || %{})
      "read_image" -> read_image(tool_instance, args || %{})
      "download_file" -> download_file(tool_instance, args || %{}, execution_context)
      "upload_file" -> upload_file(tool_instance, args || %{})
      _other -> {:error, "Unknown function: #{function_name}"}
    end
  end

  defp run_command(%ToolInstance{} = tool_instance, args) when is_map(args) do
    with {:ok, cfg} <- read_config(tool_instance),
         {:ok, auth} <- read_auth(tool_instance),
         {:ok, request} <- read_request(args, cfg.default_timeout_seconds),
         :ok <- ensure_ssh_started(),
         {:ok, result} <- execute_request(cfg, auth, request) do
      {:ok, result}
    end
  end

  defp read_image(%ToolInstance{} = tool_instance, args) when is_map(args) do
    with {:ok, cfg} <- read_config(tool_instance),
         {:ok, auth} <- read_auth(tool_instance),
         {:ok, remote_path} <- read_required_path_arg(args, "local_path"),
         :ok <- ensure_ssh_started(),
         {:ok, payload} <- read_remote_file(cfg, auth, remote_path),
         {:ok, mime_type} <- detect_image_mime(payload),
         {:ok, file} <- Files.create_from_binary(Path.basename(remote_path), mime_type, payload) do
      {:ok,
       %ExecutionResult{
         text: "Image #{file.external_id} read from #{remote_path}",
         raw: %{"path" => remote_path},
         media: [file_result(file)],
         artifacts: []
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec detect_image_mime(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def detect_image_mime(payload) when is_binary(payload) do
    case ExImageInfo.info(payload) do
      {mime_type, _width, _height, _variant} -> {:ok, mime_type}
      nil -> {:error, "File content is not a valid image."}
    end
  end

  def detect_image_mime(_payload), do: {:error, "File content is not a valid image."}

  defp download_file(
         %ToolInstance{} = tool_instance,
         args,
         %ExecutionContext{} = execution_context
       )
       when is_map(args) do
    with {:ok, cfg} <- read_config(tool_instance),
         {:ok, auth} <- read_auth(tool_instance),
         {:ok, file_external_id} <- read_required_string_arg(args, "file_id"),
         {:ok, remote_path} <- read_required_path_arg(args, "local_path"),
         :ok <- ensure_ssh_started(),
         {:ok, {_content, file, payload}} <-
           ContentFiles.load_payload_for_execution(file_external_id, execution_context),
         :ok <- write_remote_file(cfg, auth, remote_path, payload) do
      {:ok,
       %ExecutionResult{
         text: "File #{file.external_id} downloaded to #{remote_path}",
         raw: %{
           "file_id" => file.external_id,
           "path" => remote_path,
           "filename" => file.filename,
           "mime_type" => file.mime_type
         },
         media: [],
         artifacts: []
       }}
    end
  end

  defp download_file(%ToolInstance{} = _tool_instance, _args, _execution_context) do
    {:error, "Execution context is required for download_file."}
  end

  defp upload_file(%ToolInstance{} = tool_instance, args) when is_map(args) do
    with {:ok, cfg} <- read_config(tool_instance),
         {:ok, auth} <- read_auth(tool_instance),
         {:ok, remote_path} <- read_required_path_arg(args, "local_path"),
         :ok <- ensure_ssh_started(),
         {:ok, payload} <- read_remote_file(cfg, auth, remote_path),
         mime_type <- MIME.from_path(remote_path),
         {:ok, file} <- Files.create_from_binary(Path.basename(remote_path), mime_type, payload) do
      {:ok,
       %ExecutionResult{
         text: "File #{file.external_id} uploaded",
         raw: %{"path" => remote_path},
         media: [],
         artifacts: [file_result(file)]
       }}
    end
  end

  defp read_config(%ToolInstance{} = tool_instance) do
    cfg = Map.get(tool_instance, :config) || %{}
    cfg = if is_map(cfg), do: cfg, else: %{}

    host = read_string(cfg, "host", "") |> String.trim()
    username = cfg |> read_string("username", read_string(cfg, "user", "")) |> String.trim()
    port = read_integer(cfg, "port", @default_port)

    connect_timeout_seconds =
      read_integer(cfg, "connect_timeout_seconds", @default_connect_timeout_seconds)

    default_timeout_seconds =
      read_integer(cfg, "default_timeout_seconds", @default_timeout_seconds)

    with :ok <- require_present(host, "Tool instance config.host is required."),
         :ok <- require_present(username, "Tool instance config.username is required."),
         :ok <- validate_port(port),
         :ok <- validate_non_negative(connect_timeout_seconds, "config.connect_timeout_seconds"),
         :ok <- validate_non_negative(default_timeout_seconds, "config.default_timeout_seconds") do
      {:ok,
       %{
         host: host,
         username: username,
         port: port,
         connect_timeout_seconds: connect_timeout_seconds,
         connect_timeout_ms: seconds_to_timeout(connect_timeout_seconds),
         default_timeout_seconds: default_timeout_seconds
       }}
    end
  end

  defp read_auth(%ToolInstance{} = tool_instance) do
    secrets = Map.get(tool_instance, :secrets) || %{}
    secrets = if is_map(secrets), do: secrets, else: %{}

    password = read_secret_string(secrets, "password")
    private_key = read_secret_string(secrets, "private_key")

    cond do
      private_key != "" ->
        {:ok, {:private_key, private_key}}

      password != "" ->
        {:ok, {:password, password}}

      true ->
        {:error, "SSH credentials are not configured. Set either `password` or `private_key`."}
    end
  end

  defp read_request(args, default_timeout_seconds) when is_map(args) do
    with {:ok, {remote_command, argv, command_input}} <- read_command(args),
         {:ok, env_assignments, env_map} <- read_env(args),
         {:ok, timeout_seconds} <- read_timeout_seconds(args, default_timeout_seconds) do
      cwd = read_optional_string(args, "cwd")
      stdin = read_optional_string(args, "stdin")

      command_with_env =
        if env_assignments == [] do
          remote_command
        else
          Enum.join(env_assignments, " ") <> " " <> remote_command
        end

      final_command =
        if cwd == "" do
          command_with_env
        else
          "cd " <> shell_escape(cwd) <> " && " <> command_with_env
        end

      {:ok,
       %{
         command_input: command_input,
         remote_command: final_command,
         argv: argv,
         cwd: cwd,
         env: env_map,
         stdin: stdin,
         timeout_seconds: timeout_seconds,
         timeout_ms: seconds_to_timeout(timeout_seconds)
       }}
    end
  end

  defp read_command(args) when is_map(args) do
    argv_raw = Map.get(args, "argv", Map.get(args, :argv))

    argv =
      cond do
        is_list(argv_raw) ->
          Enum.map(argv_raw, &to_string/1)

        is_nil(argv_raw) ->
          nil

        true ->
          :invalid
      end

    command_text = read_optional_string(args, "command")

    cond do
      argv == :invalid ->
        {:error, "Argument `argv` must be an array of strings."}

      is_list(argv) and argv != [] ->
        {:ok, {Enum.map_join(argv, " ", &shell_escape/1), argv, command_text}}

      command_text != "" ->
        {:ok, {command_text, [], command_text}}

      true ->
        {:error, "Argument `command` or `argv` is required."}
    end
  end

  defp read_env(args) when is_map(args) do
    env_raw = Map.get(args, "env", Map.get(args, :env))

    cond do
      is_nil(env_raw) ->
        {:ok, [], %{}}

      is_map(env_raw) ->
        entries =
          env_raw
          |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
          |> Enum.sort_by(fn {k, _v} -> k end)

        with :ok <- validate_env_keys(entries) do
          assignments = Enum.map(entries, fn {k, v} -> "#{k}=#{shell_escape(v)}" end)
          {:ok, assignments, Map.new(entries)}
        end

      true ->
        {:error, "Argument `env` must be an object with string values."}
    end
  end

  defp validate_env_keys(entries) when is_list(entries) do
    case Enum.find(entries, fn {k, _v} -> not Regex.match?(@env_key_pattern, k) end) do
      nil -> :ok
      {bad, _} -> {:error, "Invalid environment variable name: #{inspect(bad)}"}
    end
  end

  defp read_timeout_seconds(args, default_timeout_seconds) when is_map(args) do
    raw = Map.get(args, "timeout_seconds", Map.get(args, :timeout_seconds))

    value =
      cond do
        is_nil(raw) -> default_timeout_seconds
        is_integer(raw) -> raw
        is_float(raw) and trunc(raw) == raw -> trunc(raw)
        true -> :invalid
      end

    if is_integer(value) and value >= 0 do
      {:ok, value}
    else
      {:error, "Argument `timeout_seconds` must be a non-negative integer."}
    end
  end

  defp read_required_path_arg(args, key) when is_map(args) do
    case read_optional_string(args, key) do
      "" -> {:error, "Argument `#{key}` is required."}
      value -> {:ok, value}
    end
  end

  defp read_required_string_arg(args, key) when is_map(args) do
    case read_optional_string(args, key) do
      "" -> {:error, "Argument `#{key}` is required."}
      value -> {:ok, value}
    end
  end

  defp execute_request(cfg, auth, request) do
    with {:ok, auth_opts, key_cb_private} <- build_auth_options(auth),
         {:ok, connection} <- connect(cfg, auth_opts, key_cb_private) do
      try do
        with {:ok, channel} <- open_channel(connection, cfg.connect_timeout_ms),
             :ok <-
               exec_remote(connection, channel, request.remote_command, cfg.connect_timeout_ms),
             :ok <- send_stdin_and_eof(connection, channel, request.stdin),
             {:ok, command_result} <- receive_result(connection, channel, request.timeout_ms) do
          stdout = decode_chunks(command_result.stdout_chunks)
          stderr = decode_chunks(command_result.stderr_chunks)

          summary =
            [stdout, stderr]
            |> Enum.reject(&(String.trim(&1) == ""))
            |> Enum.join("\n")
            |> String.trim()

          auth_method = if elem(auth, 0) == :private_key, do: "private_key", else: "password"

          raw = %{
            "host" => cfg.host,
            "port" => cfg.port,
            "username" => cfg.username,
            "auth_method" => auth_method,
            "command" => request.remote_command,
            "command_input" => request.command_input,
            "argv" => request.argv,
            "cwd" => request.cwd,
            "env" => request.env,
            "timeout_seconds" => request.timeout_seconds,
            "stdout" => stdout,
            "stderr" => stderr,
            "exit_code" =>
              if(command_result.timed_out,
                do: -9,
                else:
                  command_result.exit_status || if(command_result.exit_signal, do: 255, else: nil)
              ),
            "exit_signal" => command_result.exit_signal,
            "timed_out" => command_result.timed_out,
            "stdout_bytes_total" => command_result.stdout_bytes,
            "stderr_bytes_total" => command_result.stderr_bytes
          }

          {:ok, {summary, raw}}
        end
      after
        _ = :ssh.close(connection)
      end
    end
  end

  defp read_remote_file(cfg, auth, remote_path) do
    with {:ok, auth_opts, key_cb_private} <- build_auth_options(auth),
         {:ok, connection} <- connect(cfg, auth_opts, key_cb_private) do
      try do
        with {:ok, sftp} <- start_sftp(connection, cfg.connect_timeout_ms),
             {:ok, payload} <- sftp_read_file(sftp, remote_path) do
          {:ok, payload}
        end
      after
        _ = :ssh.close(connection)
      end
    end
  end

  defp write_remote_file(cfg, auth, remote_path, payload) when is_binary(payload) do
    with {:ok, auth_opts, key_cb_private} <- build_auth_options(auth),
         {:ok, connection} <- connect(cfg, auth_opts, key_cb_private) do
      try do
        with {:ok, sftp} <- start_sftp(connection, cfg.connect_timeout_ms),
             :ok <- sftp_write_file(sftp, remote_path, payload) do
          :ok
        end
      after
        _ = :ssh.close(connection)
      end
    end
  end

  defp start_sftp(connection, timeout_ms) do
    case :ssh_sftp.start_channel(connection, sftp_channel_options(timeout_ms)) do
      {:ok, channel} -> {:ok, channel}
      {:error, reason} -> {:error, "SSH SFTP start failed: #{format_reason(reason)}"}
    end
  end

  @doc false
  @spec sftp_channel_options(non_neg_integer() | :infinity) :: keyword()
  def sftp_channel_options(:infinity), do: [timeout: :infinity]
  def sftp_channel_options(timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0, do: [timeout: timeout_ms]

  defp sftp_read_file(channel, remote_path) do
    try do
      case :ssh_sftp.read_file(channel, to_charlist(remote_path)) do
        {:ok, payload} when is_binary(payload) -> {:ok, payload}
        {:error, reason} -> {:error, "Failed to read remote file: #{format_reason(reason)}"}
      end
    after
      _ = :ssh_sftp.stop_channel(channel)
    end
  end

  defp sftp_write_file(channel, remote_path, payload) do
    try do
      case :ssh_sftp.write_file(channel, to_charlist(remote_path), payload) do
        :ok -> :ok
        {:error, reason} -> {:error, "Failed to write remote file: #{format_reason(reason)}"}
      end
    after
      _ = :ssh_sftp.stop_channel(channel)
    end
  end

  defp ensure_ssh_started do
    case Application.ensure_all_started(:ssh) do
      {:ok, _apps} ->
        :ok

      {:error, {app, reason}} ->
        {:error, "Failed to start SSH app #{inspect(app)}: #{format_reason(reason)}"}

      {:error, reason} ->
        {:error, "Failed to start SSH application: #{format_reason(reason)}"}
    end
  end

  defp build_auth_options({:password, password}) do
    {:ok, [password: to_charlist(password), auth_methods: ~c"password,keyboard-interactive"], []}
  end

  defp build_auth_options({:private_key, private_key}) do
    private_key = private_key |> to_string() |> String.trim()

    if private_key == "" do
      {:error, "SSH private key is empty."}
    else
      {:ok, [auth_methods: ~c"publickey"], [private_key: private_key]}
    end
  end

  defp connect(cfg, auth_opts, key_cb_private) do
    options =
      [
        user: to_charlist(cfg.username),
        key_cb: {SshKeyCb, key_cb_private},
        silently_accept_hosts: false,
        user_interaction: false,
        save_accepted_host: false,
        quiet_mode: true,
        connect_timeout: cfg.connect_timeout_ms
      ] ++ auth_opts

    case :ssh.connect(to_charlist(cfg.host), cfg.port, options, cfg.connect_timeout_ms) do
      {:ok, connection} -> {:ok, connection}
      {:error, reason} -> {:error, "SSH connect failed: #{format_reason(reason)}"}
    end
  end

  defp open_channel(connection, timeout_ms) do
    case :ssh_connection.session_channel(connection, timeout_ms) do
      {:ok, channel} -> {:ok, channel}
      {:error, reason} -> {:error, "SSH session channel failed: #{format_reason(reason)}"}
    end
  end

  defp exec_remote(connection, channel, command, timeout_ms) when is_binary(command) do
    case :ssh_connection.exec(connection, channel, to_charlist(command), timeout_ms) do
      :success -> :ok
      :failure -> {:error, "SSH server rejected exec request."}
      {:error, reason} -> {:error, "SSH exec failed: #{format_reason(reason)}"}
    end
  end

  defp send_stdin_and_eof(connection, channel, stdin) do
    with :ok <- maybe_send_stdin(connection, channel, stdin),
         :ok <- send_eof(connection, channel) do
      :ok
    end
  end

  defp maybe_send_stdin(_connection, _channel, ""), do: :ok

  defp maybe_send_stdin(connection, channel, stdin) when is_binary(stdin) do
    case :ssh_connection.send(connection, channel, stdin) do
      :ok -> :ok
      {:error, reason} -> {:error, "Failed to send SSH stdin: #{format_reason(reason)}"}
    end
  end

  defp send_eof(connection, channel) do
    case :ssh_connection.send_eof(connection, channel) do
      :ok -> :ok
      {:error, :closed} -> :ok
      {:error, reason} -> {:error, "Failed to send SSH EOF: #{format_reason(reason)}"}
    end
  end

  defp receive_result(connection, channel, timeout_ms) do
    initial = %{
      stdout_chunks: [],
      stderr_chunks: [],
      stdout_bytes: 0,
      stderr_bytes: 0,
      exit_status: nil,
      exit_signal: nil,
      timed_out: false
    }

    case collect_messages(connection, channel, timeout_ms, initial) do
      {:ok, state} ->
        {:ok, state}

      {:timeout, state} ->
        _ = :ssh_connection.close(connection, channel)
        {:ok, %{state | timed_out: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_messages(connection, channel, :infinity, state) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, 0, data}} ->
        bin = IO.iodata_to_binary(data)

        collect_messages(connection, channel, :infinity, %{
          state
          | stdout_chunks: [bin | state.stdout_chunks],
            stdout_bytes: state.stdout_bytes + byte_size(bin)
        })

      {:ssh_cm, ^connection, {:data, ^channel, 1, data}} ->
        bin = IO.iodata_to_binary(data)

        collect_messages(connection, channel, :infinity, %{
          state
          | stderr_chunks: [bin | state.stderr_chunks],
            stderr_bytes: state.stderr_bytes + byte_size(bin)
        })

      {:ssh_cm, ^connection, {:exit_status, ^channel, exit_status}} ->
        collect_messages(connection, channel, :infinity, %{state | exit_status: exit_status})

      {:ssh_cm, ^connection, {:exit_signal, ^channel, signal, error, language}} ->
        collect_messages(connection, channel, :infinity, %{
          state
          | exit_signal: %{
              "signal" => to_string(signal || ""),
              "error" => to_string(error || ""),
              "language" => to_string(language || "")
            }
        })

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        {:ok, state}

      _other ->
        collect_messages(connection, channel, :infinity, state)
    end
  end

  defp collect_messages(connection, channel, timeout_ms, state) when is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_messages_until(connection, channel, deadline, state)
  end

  defp collect_messages_until(connection, channel, deadline_ms, state) do
    now = System.monotonic_time(:millisecond)
    remaining = max(deadline_ms - now, 0)

    receive do
      {:ssh_cm, ^connection, {:data, ^channel, 0, data}} ->
        bin = IO.iodata_to_binary(data)

        collect_messages_until(connection, channel, deadline_ms, %{
          state
          | stdout_chunks: [bin | state.stdout_chunks],
            stdout_bytes: state.stdout_bytes + byte_size(bin)
        })

      {:ssh_cm, ^connection, {:data, ^channel, 1, data}} ->
        bin = IO.iodata_to_binary(data)

        collect_messages_until(connection, channel, deadline_ms, %{
          state
          | stderr_chunks: [bin | state.stderr_chunks],
            stderr_bytes: state.stderr_bytes + byte_size(bin)
        })

      {:ssh_cm, ^connection, {:exit_status, ^channel, exit_status}} ->
        collect_messages_until(connection, channel, deadline_ms, %{
          state
          | exit_status: exit_status
        })

      {:ssh_cm, ^connection, {:exit_signal, ^channel, signal, error, language}} ->
        collect_messages_until(connection, channel, deadline_ms, %{
          state
          | exit_signal: %{
              "signal" => to_string(signal || ""),
              "error" => to_string(error || ""),
              "language" => to_string(language || "")
            }
        })

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        {:ok, state}

      _other ->
        collect_messages_until(connection, channel, deadline_ms, state)
    after
      remaining ->
        {:timeout, state}
    end
  end

  defp decode_chunks(chunks) when is_list(chunks) do
    bin =
      chunks
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    if String.valid?(bin) do
      bin
    else
      :unicode.characters_to_binary(bin, :latin1, :utf8)
    end
  end

  defp read_string(map, key, default) when is_map(map) do
    value = Map.get(map, key, Map.get(map, String.to_atom(key), default))
    if is_nil(value), do: default, else: to_string(value)
  end

  defp read_integer(map, key, default) when is_map(map) do
    value = Map.get(map, key, Map.get(map, String.to_atom(key), default))

    cond do
      is_integer(value) -> value
      is_float(value) -> trunc(value)
      true -> parse_integer(to_string(value), default)
    end
  end

  defp parse_integer(text, default) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {value, ""} -> value
      _other -> default
    end
  end

  defp read_secret_string(secrets, key) when is_map(secrets) do
    value = Map.get(secrets, key, Map.get(secrets, String.to_atom(key), ""))
    value |> to_string() |> String.trim()
  end

  defp read_optional_string(map, key) when is_map(map) do
    value = Map.get(map, key, Map.get(map, String.to_atom(key), ""))
    value |> to_string() |> String.trim()
  end

  defp require_present("", message), do: {:error, message}
  defp require_present(_value, _message), do: :ok

  defp validate_port(port) when is_integer(port) and port >= 1 and port <= 65_535, do: :ok

  defp validate_port(_port),
    do: {:error, "Tool instance config.port must be between 1 and 65535."}

  defp validate_non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_negative(_value, field) do
    {:error, "Tool instance #{field} must be a non-negative integer."}
  end

  defp seconds_to_timeout(seconds) when is_integer(seconds) and seconds <= 0, do: :infinity
  defp seconds_to_timeout(seconds) when is_integer(seconds), do: max(1, seconds * 1000)

  defp shell_escape(value) do
    text = to_string(value || "")

    if text == "" do
      "''"
    else
      "'" <> String.replace(text, "'", "'\"'\"'") <> "'"
    end
  end

  defp format_reason(reason) do
    cond do
      is_binary(reason) -> reason
      true -> inspect(reason)
    end
  end

  defp file_result(file) do
    %{
      "file_id" => file.id,
      "file_external_id" => file.external_id,
      "filename" => file.filename,
      "mime_type" => file.mime_type,
      "size_bytes" => file.size_bytes,
      "sha256" => file.sha256
    }
  end
end
