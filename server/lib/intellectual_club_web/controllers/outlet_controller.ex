defmodule IntellectualClubWeb.OutletController do
  @moduledoc """
  Outlet runner API (HTTP long polling + device-flow pairing).

  The runner endpoints (`poll`, `complete`, `pair_start`, `pair_poll`) are authenticated
  with a bearer token stored in a `ToolInstance` of type `outlet`.

  Pair approval is performed by an authenticated user session.
  """

  use IntellectualClubWeb, :controller

  require Logger

  alias IntellectualClub.Chat.ContentFiles
  alias IntellectualClub.Chat.Media
  alias IntellectualClub.Files
  alias IntellectualClub.Outlets.{Auth, Pairing, Runtime}
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.ImageControllerHelpers

  def poll(conn, _params) do
    payload = conn.body_params || %{}
    token = extract_token(conn, payload)
    tool_instance = Auth.tool_instance_for_token(token)

    if tool_instance == nil do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized."})
    else
      case with_runtime(fn -> Runtime.poll(tool_instance, payload) end) do
        {:ok, {:ok, %{} = response}} ->
          json(conn, response)

        {:ok, {:error, :runner_already_active}} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "Runner already connected."})

        {:error, :runtime_unavailable} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Outlet runtime is unavailable."})

        {:error, {:runtime_timeout, reason}} ->
          log_runtime_error(:poll, conn, payload, tool_instance, reason)

          conn
          |> put_status(:gateway_timeout)
          |> json(%{error: "Outlet runtime timed out."})

        {:error, {:runtime_exit, reason}} ->
          log_runtime_error(:poll, conn, payload, tool_instance, reason)

          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Outlet runtime failed."})

        {:error, {:runtime_exception, exception}} ->
          log_runtime_error(:poll, conn, payload, tool_instance, exception)

          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Outlet runtime failed."})
      end
    end
  end

  def complete(conn, _params) do
    payload = conn.body_params || %{}
    token = extract_token(conn, payload)
    tool_instance = Auth.tool_instance_for_token(token)

    if tool_instance == nil do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized."})
    else
      call_id =
        payload
        |> Map.get("call_id", Map.get(payload, :call_id, ""))
        |> to_string()
        |> String.trim()

      if call_id == "" do
        conn
        |> put_status(:bad_request)
        |> json(%{error: "call_id is required."})
      else
        _ = maybe_log_large_complete_payload(conn, payload, tool_instance, call_id)

        case with_runtime(fn ->
               Runtime.complete(tool_instance, Map.put(payload, "call_id", call_id))
             end) do
          {:ok, :ok} ->
            json(conn, %{status: "ok"})

          {:ok, {:error, :not_found}} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Call not found."})

          {:ok, {:error, :runner_already_active}} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: "Runner already connected."})

          {:error, :runtime_unavailable} ->
            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "Outlet runtime is unavailable."})

          {:error, {:runtime_timeout, reason}} ->
            log_runtime_error(:complete, conn, payload, tool_instance, reason)

            conn
            |> put_status(:gateway_timeout)
            |> json(%{error: "Outlet runtime timed out."})

          {:error, {:runtime_exit, reason}} ->
            log_runtime_error(:complete, conn, payload, tool_instance, reason)

            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "Outlet runtime failed."})

          {:error, {:runtime_exception, exception}} ->
            log_runtime_error(:complete, conn, payload, tool_instance, exception)

            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "Outlet runtime failed."})
        end
      end
    end
  end

  def upload_file(conn, %{"call_id" => call_id} = params) do
    payload = params || %{}
    token = extract_token(conn, payload)
    tool_instance = Auth.tool_instance_for_token(token)

    if tool_instance == nil do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized."})
    else
      with {:ok, _call} <-
             with_runtime(fn -> Runtime.fetch_running_call(tool_instance, call_id) end),
           {:ok, body} <- read_full_body(conn),
           :ok <- require_non_empty_body(body),
           {:ok, filename} <- uploaded_filename(conn, payload),
           {:ok, mime_type} <- uploaded_mime_type(conn, payload),
           {:ok, file} <- Files.create_from_binary(filename, mime_type, body) do
        json(conn, %{
          file: %{
            file_id: file.id,
            file_external_id: file.external_id,
            filename: file.filename,
            mime_type: file.mime_type,
            size_bytes: file.size_bytes,
            sha256: file.sha256,
            is_image: Media.image_mime_type?(file.mime_type)
          }
        })
      else
        {:ok, {:error, :not_found}} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Call not found."})

        {:error, :runtime_unavailable} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Outlet runtime is unavailable."})

        {:error, {:runtime_timeout, _reason}} ->
          conn
          |> put_status(:gateway_timeout)
          |> json(%{error: "Outlet runtime timed out."})

        {:error, {:runtime_exit, _reason}} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Outlet runtime failed."})

        {:error, {:runtime_exception, _exception}} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Outlet runtime failed."})

        {:error, message} when is_binary(message) ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: message})

        {:error, error} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(error)})
      end
    end
  end

  def download_file(conn, %{"call_id" => call_id, "content_id" => content_id} = params) do
    payload = params || %{}
    token = extract_token(conn, payload)
    tool_instance = Auth.tool_instance_for_token(token)

    if tool_instance == nil do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Unauthorized."})
    else
      case with_runtime(fn -> Runtime.fetch_running_call(tool_instance, call_id) end) do
        {:ok, {:ok, %{execution_context: execution_context}}} ->
          case ContentFiles.load_payload_for_execution(content_id, execution_context) do
            {:ok, {_content, file, payload}} ->
              disposition =
                if Media.image_mime_type?(file.mime_type), do: :inline, else: :attachment

              ImageControllerHelpers.send_loaded_file(conn, file, payload,
                disposition: disposition
              )

            {:error, _reason} ->
              conn
              |> put_status(:not_found)
              |> json(%{error: "Content not found."})
          end

        {:ok, {:error, :not_found}} ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Call not found."})

        {:error, :runtime_unavailable} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Outlet runtime is unavailable."})

        {:error, {:runtime_timeout, _reason}} ->
          conn
          |> put_status(:gateway_timeout)
          |> json(%{error: "Outlet runtime timed out."})

        {:error, {:runtime_exit, _reason}} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Outlet runtime failed."})

        {:error, {:runtime_exception, _exception}} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{error: "Outlet runtime failed."})
      end
    end
  end

  defp maybe_log_large_complete_payload(conn, payload, tool_instance, call_id)
       when is_map(payload) do
    # This endpoint is commonly hit with huge stdout/stderr payloads from tools.
    # Logging size metrics helps diagnose delivery failures (e.g., body limits,
    # connection resets) without dumping sensitive contents.
    content_length =
      conn
      |> get_req_header("content-length")
      |> List.first()
      |> parse_optional_int()

    result_text_bytes =
      payload
      |> Map.get("result_text", Map.get(payload, :result_text, ""))
      |> to_string()
      |> byte_size()

    result_raw = Map.get(payload, "result_raw", Map.get(payload, :result_raw))
    result_raw = if is_map(result_raw), do: result_raw, else: %{}

    stdout_bytes =
      case Map.get(result_raw, "stdout") do
        value when is_binary(value) -> byte_size(value)
        _ -> 0
      end

    stderr_bytes =
      case Map.get(result_raw, "stderr") do
        value when is_binary(value) -> byte_size(value)
        _ -> 0
      end

    threshold_bytes = 500_000

    if (is_integer(content_length) and content_length >= threshold_bytes) or
         result_text_bytes >= threshold_bytes or stdout_bytes >= threshold_bytes or
         stderr_bytes >= threshold_bytes do
      tool_instance_id =
        case tool_instance do
          %{id: id} when is_integer(id) -> id
          _ -> nil
        end

      runner_id = Map.get(payload, "runner_id", Map.get(payload, :runner_id))

      runner_session_id =
        Map.get(payload, "runner_session_id", Map.get(payload, :runner_session_id))

      Logger.warning(
        "Outlet complete payload large tool_instance_id=#{inspect(tool_instance_id)} " <>
          "runner_id=#{inspect(runner_id)} runner_session_id=#{inspect(runner_session_id)} " <>
          "call_id=#{inspect(call_id)} content_length=#{inspect(content_length)} " <>
          "result_text_bytes=#{result_text_bytes} stdout_bytes=#{stdout_bytes} stderr_bytes=#{stderr_bytes}"
      )
    end
  end

  def pair_start(conn, _params) do
    payload = conn.body_params || %{}

    result = Pairing.start_pairing!(conn, payload)

    json(conn, %{
      status: "ok",
      device_code: result.device_code,
      user_code: result.user_code,
      verification_url: result.verification_url,
      expires_in: result.expires_in,
      interval: result.interval,
      suggested_tool_name: result.suggested_tool_name
    })
  end

  def pair_poll(conn, _params) do
    payload = conn.body_params || %{}

    device_code =
      payload
      |> Map.get("device_code", Map.get(payload, :device_code, ""))
      |> to_string()
      |> String.trim()

    case Pairing.poll_pairing!(device_code) do
      {:ok, %{} = response} ->
        json(conn, response)

      {:error, %{} = response} ->
        status =
          case Map.get(response, :error) || Map.get(response, "error") do
            "Pairing is approved but token is missing." -> :internal_server_error
            _ -> :bad_request
          end

        conn
        |> put_status(status)
        |> json(response)
    end
  end

  def pair_approve(conn, _params) do
    with {:ok, actor} <- Helpers.require_actor(conn) do
      payload = conn.body_params || %{}

      user_code =
        payload
        |> Map.get(
          "user_code",
          Map.get(payload, :user_code, Map.get(payload, "code", Map.get(payload, :code, "")))
        )
        |> to_string()
        |> String.trim()

      tool_name =
        payload
        |> Map.get("tool_name", Map.get(payload, :tool_name, ""))
        |> to_string()
        |> String.trim()

      case Pairing.approve_pairing!(user_code, actor, tool_name) do
        {:ok, %{tool_instance_id: tool_instance_id, tool_name: tool_name}} ->
          json(conn, %{status: "ok", tool_instance_id: tool_instance_id, tool_name: tool_name})

        {:error, message} ->
          {http_status, message} = normalize_pair_approve_error(message)

          conn
          |> put_status(http_status)
          |> json(%{error: message})
      end
    end
  end

  defp normalize_pair_approve_error(message) when is_binary(message) do
    case message do
      "Pairing code not found." -> {:not_found, message}
      "Pairing code expired." -> {:bad_request, message}
      "Pairing code is not pending." -> {:bad_request, message}
      "user_code is required." -> {:bad_request, message}
      other -> {:unprocessable_entity, other}
    end
  end

  defp with_runtime(fun) when is_function(fun, 0) do
    try do
      {:ok, fun.()}
    rescue
      exception ->
        {:error, {:runtime_exception, exception}}
    catch
      :exit, {:noproc, _} -> {:error, :runtime_unavailable}
      :exit, {:timeout, _} = reason -> {:error, {:runtime_timeout, reason}}
      :exit, :timeout = reason -> {:error, {:runtime_timeout, reason}}
      :exit, reason -> {:error, {:runtime_exit, reason}}
    end
  end

  defp log_runtime_error(kind, conn, payload, tool_instance, reason)
       when kind in [:poll, :complete] and is_map(payload) do
    tool_instance_id =
      case tool_instance do
        %{id: id} when is_integer(id) -> id
        _ -> nil
      end

    runner_id = Map.get(payload, "runner_id", Map.get(payload, :runner_id))

    runner_session_id =
      Map.get(payload, "runner_session_id", Map.get(payload, :runner_session_id))

    call_id = Map.get(payload, "call_id", Map.get(payload, :call_id))

    content_length =
      conn
      |> get_req_header("content-length")
      |> List.first()
      |> parse_optional_int()

    Logger.warning(
      "Outlet runtime error kind=#{kind} tool_instance_id=#{inspect(tool_instance_id)} " <>
        "runner_id=#{inspect(runner_id)} runner_session_id=#{inspect(runner_session_id)} " <>
        "call_id=#{inspect(call_id)} content_length=#{inspect(content_length)} " <>
        "reason=#{inspect(reason)}"
    )
  end

  defp parse_optional_int(nil), do: nil

  defp parse_optional_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_optional_int(_other), do: nil

  defp read_full_body(conn, acc \\ "") do
    case read_body(conn) do
      {:ok, chunk, _conn} ->
        {:ok, acc <> chunk}

      {:more, chunk, conn} ->
        read_full_body(conn, acc <> chunk)

      {:error, reason} ->
        {:error, "Failed to read request body: #{inspect(reason)}"}
    end
  end

  defp require_non_empty_body(body) when is_binary(body) do
    if byte_size(body) > 0, do: :ok, else: {:error, "Request body is empty."}
  end

  defp uploaded_filename(conn, payload) do
    value =
      Map.get(payload, "filename", Map.get(payload, :filename)) ||
        conn |> get_req_header("x-filename") |> List.first()

    case value |> to_string() |> String.trim() do
      "" -> {:error, "filename is required."}
      filename -> {:ok, filename}
    end
  end

  defp uploaded_mime_type(conn, payload) do
    header_content_type = conn |> get_req_header("content-type") |> List.first()

    value =
      Map.get(payload, "mime_type", Map.get(payload, :mime_type)) ||
        header_content_type || "application/octet-stream"

    case value |> to_string() |> String.trim() do
      "" -> {:ok, "application/octet-stream"}
      mime_type -> {:ok, mime_type}
    end
  end

  defp extract_token(conn, payload) when is_map(payload) do
    auth =
      conn
      |> get_req_header("authorization")
      |> List.first()
      |> to_string()
      |> String.trim()

    token =
      if String.starts_with?(String.downcase(auth), "bearer ") do
        auth
        |> String.split(" ", parts: 2)
        |> List.last()
        |> to_string()
        |> String.trim()
      else
        ""
      end

    token =
      if token != "" do
        token
      else
        conn
        |> get_req_header("x-outlet-token")
        |> List.first()
        |> to_string()
        |> String.trim()
      end

    token =
      if token != "" do
        token
      else
        payload
        |> Map.get("token", Map.get(payload, :token, ""))
        |> to_string()
        |> String.trim()
      end

    token
  end
end
