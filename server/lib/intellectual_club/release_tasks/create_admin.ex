defmodule IntellectualClub.ReleaseTasks.CreateAdmin do
  @moduledoc """
  Interactive release task for creating administrator accounts.
  """

  alias IntellectualClub.Accounts.AdminProvisioning
  alias IntellectualClub.Repo

  @json_stdin_flag "--json-stdin"
  @line_stdin_flag "--line-stdin"

  @type error_code ::
          :invalid_arguments
          | :invalid_input
          | :password_mismatch
          | :username_taken
          | :validation_failed
          | :operation_failed

  @type task_error :: {error_code(), String.t()}

  @doc """
  Runs the command and terminates the VM with a non-zero status on failure.
  """
  @spec main([String.t()]) :: no_return() | :ok
  def main(args \\ System.argv()) do
    json_output? = args == [@json_stdin_flag]

    case run(args) do
      {:ok, user} ->
        print_success(user.username, json_output?)
        :ok

      {:error, code, message} ->
        print_error(code, message, json_output?)
        System.halt(1)
    end
  end

  @doc false
  @spec run([String.t()], keyword()) ::
          {:ok, IntellectualClub.Accounts.User.t()} | {:error, error_code(), String.t()}
  def run(args, opts \\ []) when is_list(args) and is_list(opts) do
    provisioner = Keyword.get(opts, :provisioner, &provision_with_migrations/1)

    with {:ok, attributes} <- read_attributes(args),
         :ok <- validate_confirmation(attributes),
         {:ok, user} <- provisioner.(attributes) do
      {:ok, user}
    else
      {:error, code, message} ->
        {:error, code, message}

      {:error, :username_taken} ->
        {:error, :username_taken, "Username already exists."}

      {:error, %Ash.Error.Invalid{} = error} ->
        {:error, :validation_failed, format_ash_error(error)}

      {:error, error} ->
        {:error, :operation_failed, format_error(error)}
    end
  rescue
    error -> {:error, :operation_failed, Exception.message(error)}
  catch
    kind, reason -> {:error, :operation_failed, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp read_attributes([@json_stdin_flag]) do
    with {:ok, payload} <- read_all_stdin(),
         {:ok, decoded} <- Jason.decode(payload),
         {:ok, attributes} <- attributes_from_json(decoded) do
      {:ok, attributes}
    else
      {:error, %Jason.DecodeError{}} ->
        {:error, :invalid_input, "Expected a JSON object on stdin."}

      {:error, code, message} ->
        {:error, code, message}

      {:error, reason} ->
        {:error, :invalid_input, "Failed to read stdin: #{inspect(reason)}"}
    end
  end

  defp read_attributes([@line_stdin_flag]) do
    with {:ok, username} <- read_stdin_line(),
         {:ok, password} <- read_stdin_line(),
         {:ok, password_confirmation} <- read_stdin_line() do
      {:ok,
       %{
         username: username,
         password: password,
         password_confirmation: password_confirmation
       }}
    end
  end

  defp read_attributes(_args) do
    {:error, :invalid_arguments, "Usage: create-admin"}
  end

  defp read_stdin_line do
    case IO.read(:stdio, :line) do
      data when is_binary(data) ->
        {:ok, data |> String.trim_trailing("\n") |> String.trim_trailing("\r")}

      :eof ->
        {:error, :invalid_input, "Input ended before all fields were provided."}

      {:error, reason} ->
        {:error, :invalid_input, "Failed to read input: #{inspect(reason)}"}
    end
  end

  defp read_all_stdin do
    case IO.read(:stdio, :eof) do
      data when is_binary(data) -> {:ok, data}
      :eof -> {:error, :invalid_input, "Expected a JSON object on stdin."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attributes_from_json(%{
         "username" => username,
         "password" => password,
         "password_confirmation" => password_confirmation
       })
       when is_binary(username) and is_binary(password) and is_binary(password_confirmation) do
    {:ok,
     %{
       username: username,
       password: password,
       password_confirmation: password_confirmation
     }}
  end

  defp attributes_from_json(_payload) do
    {:error, :invalid_input,
     "JSON input must contain string username, password, and password_confirmation fields."}
  end

  defp validate_confirmation(%{password: password, password_confirmation: password}) do
    :ok
  end

  defp validate_confirmation(_attributes) do
    {:error, :password_mismatch, "Passwords do not match."}
  end

  defp provision_with_migrations(attributes) do
    case Ecto.Migrator.with_repo(Repo, fn repo ->
           Ecto.Migrator.run(repo, :up, all: true)
           AdminProvisioning.create_admin(attributes)
         end) do
      {:ok, result, _started_apps} -> result
      {:error, error} -> {:error, error}
    end
  end

  defp format_ash_error(%Ash.Error.Invalid{errors: errors}) when errors != [] do
    errors
    |> Enum.map(&Exception.message/1)
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp format_ash_error(error), do: Exception.message(error)

  defp format_error(error) when is_exception(error), do: Exception.message(error)
  defp format_error(error), do: inspect(error)

  defp print_success(username, true) do
    IO.puts(Jason.encode!(%{ok: true, username: username}))
  end

  defp print_success(username, false) do
    IO.puts("Administrator created: #{username}")
  end

  defp print_error(code, message, true) do
    IO.puts(:stderr, Jason.encode!(%{ok: false, code: code, message: message}))
  end

  defp print_error(_code, message, false) do
    IO.puts(:stderr, "Failed to create administrator: #{message}")
  end
end
