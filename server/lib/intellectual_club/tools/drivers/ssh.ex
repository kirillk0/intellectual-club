defmodule IntellectualClub.Tools.Drivers.Ssh do
  @moduledoc """
  Native SSH driver.

  Exposes fixed functions that execute commands directly or as durable background tasks.
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

  alias IntellectualClub.BackgroundTasks
  alias IntellectualClub.Chat.ContentFiles
  alias IntellectualClub.Files
  alias IntellectualClub.TokenCounter
  alias IntellectualClub.Tools.Drivers.SshKeyCb
  alias IntellectualClub.Tools.ExecutionContext
  alias IntellectualClub.Tools.ExecutionResult
  alias IntellectualClub.Tools.ToolInstance

  @default_port 22
  @default_connect_timeout_seconds 10
  @default_timeout_seconds 60
  @background_event_chunk_bytes 8 * 1024
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
  def supports_artifacts?, do: true

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
          "x-ui" => %{"order" => 10, "placeholder" => "example.com"}
        },
        "port" => %{
          "type" => "integer",
          "title" => "Port",
          "description" => "SSH port.",
          "minimum" => 1,
          "x-ui" => %{"order" => 20}
        },
        "username" => %{
          "type" => "string",
          "title" => "Username",
          "description" => "SSH username.",
          "x-ui" => %{"order" => 30, "placeholder" => "root"}
        },
        "connect_timeout_seconds" => %{
          "type" => "integer",
          "title" => "Connect timeout (seconds)",
          "description" => "Connection/handshake timeout in seconds.",
          "minimum" => 0,
          "x-ui" => %{"order" => 100}
        },
        "default_timeout_seconds" => %{
          "type" => "integer",
          "title" => "Default command timeout (seconds)",
          "description" => "Default command timeout in seconds when argument is omitted.",
          "minimum" => 0,
          "x-ui" => %{"order" => 110}
        }
      },
      "required" => ["host", "username"],
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
    command_schema = %{
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
    }

    [
      %{
        "name" => "run_command",
        "description" =>
          "Run a shell command on the SSH host and return stdout/stderr. If `argv` is provided, it takes precedence.",
        "schema" => command_schema,
        "enabled" => true
      },
      %{
        "name" => "run_command_background",
        "description" =>
          "Start a shell command on the SSH host in the background and return a background task ID immediately.",
        "schema" => command_schema,
        "enabled" => false,
        "enabled_by_default" => false
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
      "run_command" -> run_command(tool_instance, args)
      "run_command_background" -> start_background_command(tool_instance, args, execution_context)
      "read_image" -> read_image(tool_instance, args)
      "download_file" -> download_file(tool_instance, args, execution_context)
      "upload_file" -> upload_file(tool_instance, args)
      _other -> {:error, "Unknown function: #{function_name}"}
    end
  end

  defp run_command(
         %ToolInstance{} = tool_instance,
         args,
         progress_callback \\ nil,
         collector_options \\ []
       )
       when is_map(args) do
    with {:ok, cfg} <- read_config(tool_instance),
         {:ok, auth} <- read_auth(tool_instance),
         {:ok, request} <- read_request(args, cfg.default_timeout_seconds),
         :ok <- ensure_ssh_started(),
         {:ok, result} <-
           execute_request(cfg, auth, request, progress_callback, collector_options) do
      {:ok, result}
    end
  end

  defp start_background_command(
         %ToolInstance{} = tool_instance,
         args,
         %ExecutionContext{} = execution_context
       ) do
    BackgroundTasks.start_tool(tool_instance, "run_command", args, execution_context)
  end

  defp start_background_command(_tool_instance, _args, _execution_context) do
    {:error, "Background SSH command requires generation execution context."}
  end

  @doc false
  def execute_background_command(
        task,
        %ToolInstance{} = tool_instance,
        "run_command",
        args,
        %ExecutionContext{}
      )
      when is_map(args) do
    max_output_tokens = background_max_output_tokens(tool_instance)
    progress_key = {__MODULE__, :background_progress_bytes, task.id}
    truncated_key = {__MODULE__, :background_progress_truncated, task.id}
    Process.put(progress_key, 0)
    Process.put(truncated_key, false)

    progress_callback = fn stream, data ->
      used_bytes = Process.get(progress_key, 0)
      byte_limit = token_byte_limit(max_output_tokens)
      remaining_bytes = max(byte_limit - used_bytes, 0)
      stored = valid_utf8_prefix(data, remaining_bytes)

      if byte_size(stored) > 0 do
        Process.put(progress_key, used_bytes + byte_size(stored))
        append_background_event_chunks(task, stream, stored)
      end

      if byte_size(stored) < byte_size(data) do
        Process.put(truncated_key, true)
      end

      :ok
    end

    result =
      case run_command(tool_instance, args, progress_callback,
             capture_byte_limit: token_byte_limit(max_output_tokens),
             stream_utf8: true,
             background_task_id: task.id
           ) do
        {:ok, value} ->
          {:ok,
           limit_background_command_result(
             value,
             max_output_tokens,
             Process.get(truncated_key, false)
           )}

        {:error, reason} ->
          {:failed, background_ssh_error(reason)}
      end

    Process.delete(progress_key)
    Process.delete(truncated_key)
    result
  end

  def execute_background_command(_task, _tool_instance, function_name, _args, _context) do
    {:error, "Unsupported SSH background function: #{function_name}"}
  end

  @doc false
  def cancel_background_command(task_id) when is_binary(task_id) do
    cancel_key = background_cancel_key(task_id)

    IntellectualClub.BackgroundTasks.ProcessRegistry
    |> Registry.lookup(cancel_key)
    |> Enum.each(fn {_pid, cancel_ref} -> close_background_cancel_ref(cancel_ref) end)

    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc false
  def register_background_cancel_ref(task_id, connection, channel, closer)
      when is_binary(task_id) and is_function(closer, 1) do
    Registry.register(
      IntellectualClub.BackgroundTasks.ProcessRegistry,
      background_cancel_key(task_id),
      %{connection: connection, channel: channel, closer: closer}
    )

    :ok
  end

  @doc false
  def collect_background_output_for_test(messages, byte_limit, progress_callback \\ nil)
      when is_list(messages) and is_integer(byte_limit) and byte_limit >= 0 do
    connection = make_ref()
    channel = 1

    Enum.each(messages, fn
      {:stdout, data} ->
        send(self(), {:ssh_cm, connection, {:data, channel, 0, data}})

      {:stderr, data} ->
        send(self(), {:ssh_cm, connection, {:data, channel, 1, data}})

      {:exit_status, status} ->
        send(self(), {:ssh_cm, connection, {:exit_status, channel, status}})
    end)

    send(self(), {:ssh_cm, connection, {:closed, channel}})

    with {:ok, state} <-
           receive_result(connection, channel, 1_000, progress_callback,
             capture_byte_limit: byte_limit,
             stream_utf8: true
           ) do
      {:ok,
       %{
         stdout: decode_chunks(state.stdout_chunks),
         stderr: decode_chunks(state.stderr_chunks),
         stdout_bytes: state.stdout_bytes,
         stderr_bytes: state.stderr_bytes,
         captured_bytes: state.captured_bytes,
         capture_truncated: state.capture_truncated
       }}
    end
  end

  defp background_max_output_tokens(%ToolInstance{max_output_tokens: value})
       when is_integer(value) and value >= 0,
       do: value

  defp background_max_output_tokens(_tool_instance), do: 20_000

  defp token_byte_limit(max_output_tokens)
       when is_integer(max_output_tokens) and max_output_tokens >= 0 do
    trunc(max_output_tokens * 3.5)
  end

  defp valid_utf8_prefix(data, max_bytes) when is_binary(data) and is_integer(max_bytes) do
    data =
      if String.valid?(data), do: data, else: :unicode.characters_to_binary(data, :latin1, :utf8)

    max_bytes = max(max_bytes, 0)

    cond do
      max_bytes == 0 ->
        ""

      byte_size(data) <= max_bytes ->
        data

      true ->
        do_valid_utf8_prefix(data, max_bytes)
    end
  end

  defp append_background_event_chunks(_task, _stream, ""), do: :ok

  defp append_background_event_chunks(task, stream, data) when is_binary(data) do
    chunk = valid_utf8_prefix(data, @background_event_chunk_bytes)

    if chunk == "" do
      :ok
    else
      _ = BackgroundTasks.append_event(task, stream, chunk)
      rest_size = byte_size(data) - byte_size(chunk)

      if rest_size > 0 do
        rest = binary_part(data, byte_size(chunk), rest_size)
        append_background_event_chunks(task, stream, rest)
      else
        :ok
      end
    end
  end

  defp do_valid_utf8_prefix(data, max_bytes) do
    prefix = binary_part(data, 0, max_bytes)

    if String.valid?(prefix) do
      prefix
    else
      1..4
      |> Enum.reduce_while("", fn trim, _fallback ->
        size = max(max_bytes - trim, 0)
        candidate = binary_part(data, 0, size)

        if String.valid?(candidate), do: {:halt, candidate}, else: {:cont, ""}
      end)
    end
  end

  defp limit_background_command_result({text, %{} = raw}, max_output_tokens, progress_truncated?) do
    byte_limit = token_byte_limit(max_output_tokens)
    stdout = to_string(Map.get(raw, "stdout", ""))
    stderr = to_string(Map.get(raw, "stderr", ""))
    limited_stdout = valid_utf8_prefix(stdout, byte_limit)
    remaining = max(byte_limit - byte_size(limited_stdout), 0)
    limited_stderr = valid_utf8_prefix(stderr, remaining)
    text = to_string(text || "")
    limited_text = valid_utf8_prefix(text, byte_limit)

    truncated? =
      progress_truncated? or TokenCounter.estimate(text) > max_output_tokens or
        byte_size(limited_stdout) < byte_size(stdout) or
        byte_size(limited_stderr) < byte_size(stderr)

    raw =
      raw
      |> Map.put("stdout", limited_stdout)
      |> Map.put("stderr", limited_stderr)
      |> Map.put("output_truncated", truncated?)

    %ExecutionResult{text: limited_text, raw: raw, media: [], artifacts: []}
  end

  defp validate_background_completion(command_result, progress_callback)
       when is_function(progress_callback, 2) do
    if command_result.timed_out or not is_nil(command_result.exit_status) or
         not is_nil(command_result.exit_signal) do
      :ok
    else
      {:error, "SSH channel closed before command termination could be confirmed."}
    end
  end

  defp validate_background_completion(_command_result, _progress_callback), do: :ok

  defp background_ssh_error(reason) do
    message = safe_error_message(reason)

    if ssh_not_started_error?(message) do
      %{
        "code" => "ssh_execution_failed",
        "message" => message,
        "outcome" => "not_started"
      }
    else
      %{
        "code" => "execution_lost",
        "message" => message,
        "outcome" => "unknown"
      }
    end
  end

  defp ssh_not_started_error?(message) when is_binary(message) do
    Enum.any?(
      [
        "Tool instance ",
        "SSH credentials ",
        "Argument `",
        "Invalid environment variable name",
        "Failed to start SSH",
        "SSH connect failed",
        "SSH session channel failed",
        "SSH server rejected exec request"
      ],
      &String.starts_with?(message, &1)
    )
  end

  defp safe_error_message(reason) when is_binary(reason), do: reason
  defp safe_error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error_message(reason), do: inspect(reason)

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
    argv_raw = Map.get(args, "argv")

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
    env_raw = Map.get(args, "env")

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
    raw = Map.get(args, "timeout_seconds")

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

  defp execute_request(cfg, auth, request, progress_callback, collector_options) do
    with {:ok, auth_opts, key_cb_private} <- build_auth_options(auth),
         {:ok, connection} <- connect(cfg, auth_opts, key_cb_private) do
      register_background_connection(collector_options, connection)

      try do
        with {:ok, channel} <- open_channel(connection, cfg.connect_timeout_ms),
             :ok <- update_background_channel(collector_options, channel),
             :ok <-
               exec_remote(connection, channel, request.remote_command, cfg.connect_timeout_ms),
             :ok <- send_stdin_and_eof(connection, channel, request.stdin),
             {:ok, command_result} <-
               receive_result(
                 connection,
                 channel,
                 request.timeout_ms,
                 progress_callback,
                 collector_options
               ),
             :ok <- validate_background_completion(command_result, progress_callback) do
          stdout = decode_chunks(command_result.stdout_chunks)
          stderr = decode_chunks(command_result.stderr_chunks)

          summary =
            format_run_command_text(
              stdout,
              stderr,
              command_result.timed_out,
              request.timeout_seconds
            )

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
        unregister_background_connection(collector_options)
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

  def sftp_channel_options(timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0,
    do: [timeout: timeout_ms]

  @doc false
  @spec format_run_command_text(String.t(), String.t(), boolean(), non_neg_integer() | nil) ::
          String.t()
  def format_run_command_text(stdout, stderr, timed_out, timeout_seconds) do
    [stdout, stderr]
    |> Enum.reject(&(String.trim(to_string(&1 || "")) == ""))
    |> Enum.join("\n")
    |> String.trim()
    |> maybe_append_command_timeout_notice(timed_out, timeout_seconds)
  end

  defp maybe_append_command_timeout_notice(text, true, timeout_seconds) do
    notice = command_timeout_notice(timeout_seconds)
    text = String.trim(to_string(text || ""))

    if text == "" do
      notice
    else
      text <> "\n\n" <> notice
    end
  end

  defp maybe_append_command_timeout_notice(text, _timed_out, _timeout_seconds),
    do: String.trim(to_string(text || ""))

  defp command_timeout_notice(timeout_seconds)
       when is_integer(timeout_seconds) and timeout_seconds > 0 do
    unit = if timeout_seconds == 1, do: "second", else: "seconds"
    "[timeout] Command exceeded timeout of #{timeout_seconds} #{unit}."
  end

  defp command_timeout_notice(_timeout_seconds), do: "[timeout] Command exceeded timeout."

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

  defp receive_result(
         connection,
         channel,
         timeout_ms,
         progress_callback,
         collector_options
       ) do
    initial = %{
      stdout_chunks: [],
      stderr_chunks: [],
      stdout_bytes: 0,
      stderr_bytes: 0,
      stdout_carry: "",
      stderr_carry: "",
      captured_bytes: 0,
      capture_byte_limit: Keyword.get(collector_options, :capture_byte_limit, :infinity),
      capture_truncated: false,
      stream_utf8: Keyword.get(collector_options, :stream_utf8, false),
      exit_status: nil,
      exit_signal: nil,
      timed_out: false
    }

    case collect_messages(connection, channel, timeout_ms, initial, progress_callback) do
      {:ok, state} ->
        {:ok, flush_stream_carries(state, progress_callback)}

      {:timeout, state} ->
        _ = :ssh_connection.close(connection, channel)
        state = flush_stream_carries(state, progress_callback)
        {:ok, %{state | timed_out: true}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_messages(connection, channel, :infinity, state, progress_callback) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, 0, data}} ->
        bin = IO.iodata_to_binary(data)
        state = collect_stream_chunk(state, :stdout, bin, progress_callback)

        collect_messages(
          connection,
          channel,
          :infinity,
          state,
          progress_callback
        )

      {:ssh_cm, ^connection, {:data, ^channel, 1, data}} ->
        bin = IO.iodata_to_binary(data)
        state = collect_stream_chunk(state, :stderr, bin, progress_callback)

        collect_messages(
          connection,
          channel,
          :infinity,
          state,
          progress_callback
        )

      {:ssh_cm, ^connection, {:exit_status, ^channel, exit_status}} ->
        collect_messages(
          connection,
          channel,
          :infinity,
          %{state | exit_status: exit_status},
          progress_callback
        )

      {:ssh_cm, ^connection, {:exit_signal, ^channel, signal, error, language}} ->
        collect_messages(
          connection,
          channel,
          :infinity,
          %{
            state
            | exit_signal: %{
                "signal" => to_string(signal || ""),
                "error" => to_string(error || ""),
                "language" => to_string(language || "")
              }
          },
          progress_callback
        )

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        {:ok, state}

      _other ->
        collect_messages(connection, channel, :infinity, state, progress_callback)
    end
  end

  defp collect_messages(connection, channel, timeout_ms, state, progress_callback)
       when is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_messages_until(connection, channel, deadline, state, progress_callback)
  end

  defp collect_messages_until(connection, channel, deadline_ms, state, progress_callback) do
    now = System.monotonic_time(:millisecond)
    remaining = max(deadline_ms - now, 0)

    receive do
      {:ssh_cm, ^connection, {:data, ^channel, 0, data}} ->
        bin = IO.iodata_to_binary(data)
        state = collect_stream_chunk(state, :stdout, bin, progress_callback)

        collect_messages_until(
          connection,
          channel,
          deadline_ms,
          state,
          progress_callback
        )

      {:ssh_cm, ^connection, {:data, ^channel, 1, data}} ->
        bin = IO.iodata_to_binary(data)
        state = collect_stream_chunk(state, :stderr, bin, progress_callback)

        collect_messages_until(
          connection,
          channel,
          deadline_ms,
          state,
          progress_callback
        )

      {:ssh_cm, ^connection, {:exit_status, ^channel, exit_status}} ->
        collect_messages_until(
          connection,
          channel,
          deadline_ms,
          %{
            state
            | exit_status: exit_status
          },
          progress_callback
        )

      {:ssh_cm, ^connection, {:exit_signal, ^channel, signal, error, language}} ->
        collect_messages_until(
          connection,
          channel,
          deadline_ms,
          %{
            state
            | exit_signal: %{
                "signal" => to_string(signal || ""),
                "error" => to_string(error || ""),
                "language" => to_string(language || "")
              }
          },
          progress_callback
        )

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        {:ok, state}

      _other ->
        collect_messages_until(connection, channel, deadline_ms, state, progress_callback)
    after
      remaining ->
        {:timeout, state}
    end
  end

  defp emit_progress(callback, stream, data)
       when is_function(callback, 2) and stream in [:stdout, :stderr] and is_binary(data) do
    callback.(stream, data)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp emit_progress(_callback, _stream, _data), do: :ok

  defp collect_stream_chunk(%{stream_utf8: true} = state, stream, data, progress_callback) do
    carry_key = stream_carry_key(stream)
    carry = Map.fetch!(state, carry_key)
    {text, carry} = decode_stream_chunk(carry, data)

    state
    |> Map.put(carry_key, carry)
    |> increment_stream_bytes(stream, byte_size(data))
    |> capture_stream_chunk(stream, text)
    |> tap(fn _state -> emit_progress(progress_callback, stream, text) end)
  end

  defp collect_stream_chunk(state, stream, data, progress_callback) do
    emit_progress(progress_callback, stream, data)

    state
    |> increment_stream_bytes(stream, byte_size(data))
    |> capture_stream_chunk(stream, data)
  end

  defp increment_stream_bytes(state, :stdout, count) do
    %{state | stdout_bytes: state.stdout_bytes + count}
  end

  defp increment_stream_bytes(state, :stderr, count) do
    %{state | stderr_bytes: state.stderr_bytes + count}
  end

  defp capture_stream_chunk(state, _stream, ""), do: state

  defp capture_stream_chunk(%{capture_byte_limit: :infinity} = state, stream, data) do
    put_stream_chunk(state, stream, data)
  end

  defp capture_stream_chunk(state, stream, data) do
    remaining = max(state.capture_byte_limit - state.captured_bytes, 0)
    captured = valid_utf8_prefix(data, remaining)

    state =
      state
      |> put_stream_chunk(stream, captured)
      |> Map.put(:captured_bytes, state.captured_bytes + byte_size(captured))

    if byte_size(captured) < byte_size(data) do
      %{state | capture_truncated: true}
    else
      state
    end
  end

  defp put_stream_chunk(state, _stream, ""), do: state

  defp put_stream_chunk(state, :stdout, data) do
    %{state | stdout_chunks: [data | state.stdout_chunks]}
  end

  defp put_stream_chunk(state, :stderr, data) do
    %{state | stderr_chunks: [data | state.stderr_chunks]}
  end

  defp flush_stream_carries(%{stream_utf8: false} = state, _progress_callback), do: state

  defp flush_stream_carries(state, progress_callback) do
    Enum.reduce([:stdout, :stderr], state, fn stream, acc ->
      carry_key = stream_carry_key(stream)

      case Map.fetch!(acc, carry_key) do
        "" ->
          acc

        carry ->
          text = :unicode.characters_to_binary(carry, :latin1, :utf8)
          emit_progress(progress_callback, stream, text)

          acc
          |> Map.put(carry_key, "")
          |> capture_stream_chunk(stream, text)
      end
    end)
  end

  defp stream_carry_key(:stdout), do: :stdout_carry
  defp stream_carry_key(:stderr), do: :stderr_carry

  defp decode_stream_chunk(carry, data) when is_binary(carry) and is_binary(data) do
    combined = carry <> data

    case :unicode.characters_to_binary(combined, :utf8, :utf8) do
      text when is_binary(text) ->
        {text, ""}

      {:incomplete, text, rest} ->
        {IO.iodata_to_binary(text), IO.iodata_to_binary(rest)}

      {:error, text, rest} ->
        prefix = IO.iodata_to_binary(text)
        fallback = rest |> IO.iodata_to_binary() |> :unicode.characters_to_binary(:latin1, :utf8)
        {prefix <> fallback, ""}
    end
  end

  defp background_cancel_key(task_id), do: {:ssh_background_command, task_id}

  defp register_background_connection(collector_options, connection) do
    case Keyword.get(collector_options, :background_task_id) do
      task_id when is_binary(task_id) ->
        Registry.register(
          IntellectualClub.BackgroundTasks.ProcessRegistry,
          background_cancel_key(task_id),
          %{connection: connection, channel: nil}
        )

        :ok

      _other ->
        :ok
    end
  end

  defp update_background_channel(collector_options, channel) do
    case Keyword.get(collector_options, :background_task_id) do
      task_id when is_binary(task_id) ->
        _ =
          Registry.update_value(
            IntellectualClub.BackgroundTasks.ProcessRegistry,
            background_cancel_key(task_id),
            &Map.put(&1, :channel, channel)
          )

        :ok

      _other ->
        :ok
    end
  end

  defp unregister_background_connection(collector_options) do
    case Keyword.get(collector_options, :background_task_id) do
      task_id when is_binary(task_id) ->
        Registry.unregister(
          IntellectualClub.BackgroundTasks.ProcessRegistry,
          background_cancel_key(task_id)
        )

      _other ->
        :ok
    end
  rescue
    _exception -> :ok
  end

  defp close_background_cancel_ref(%{closer: closer} = cancel_ref)
       when is_function(closer, 1) do
    closer.(Map.drop(cancel_ref, [:closer]))
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp close_background_cancel_ref(%{connection: connection, channel: channel}) do
    if not is_nil(channel) do
      safe_ssh_close(fn -> :ssh_connection.close(connection, channel) end)
    end

    safe_ssh_close(fn -> :ssh.close(connection) end)
  end

  defp close_background_cancel_ref(_cancel_ref), do: :ok

  defp safe_ssh_close(close_fun) when is_function(close_fun, 0) do
    _ = close_fun.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
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
    value = Map.get(map, key, default)
    if is_nil(value), do: default, else: to_string(value)
  end

  defp read_integer(map, key, default) when is_map(map) do
    value = Map.get(map, key, default)

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
    value = Map.get(secrets, key, "")
    value |> to_string() |> String.trim()
  end

  defp read_optional_string(map, key) when is_map(map) do
    value = Map.get(map, key, "")
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
      file_id: file.id,
      file_external_id: file.external_id,
      filename: file.filename,
      mime_type: file.mime_type,
      size_bytes: file.size_bytes,
      sha256: file.sha256
    }
  end
end
