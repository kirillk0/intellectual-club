defmodule IntellectualClub.Outlets.Pairing do
  @moduledoc """
  Outlet runner device-flow pairing.

  Pairing requests are persisted in the database to survive server restarts.
  """

  alias IntellectualClub.Outlets.PairingRequest
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  @pairing_expires_seconds 15 * 60
  @pairing_poll_interval_seconds 2.0

  @user_code_alphabet "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @user_code_groups 2
  @user_code_group_len 4

  @type start_result :: %{
          device_code: String.t(),
          user_code: String.t(),
          verification_url: String.t(),
          expires_in: non_neg_integer(),
          interval: float(),
          suggested_tool_name: String.t()
        }

  @spec start_pairing!(Plug.Conn.t(), map()) :: start_result()
  def start_pairing!(conn, payload) when is_map(payload) do
    metadata =
      case Map.get(payload, "metadata", Map.get(payload, :metadata)) do
        %{} = m -> m
        _ -> %{}
      end

    runner_kind =
      payload
      |> Map.get(
        "runner_kind",
        Map.get(payload, :runner_kind, Map.get(payload, "kind", Map.get(payload, :kind, "")))
      )
      |> to_string()
      |> String.trim()
      |> String.slice(0, 64)

    requested_name =
      payload
      |> Map.get("requested_name", Map.get(payload, :requested_name, ""))
      |> to_string()
      |> String.trim()
      |> String.slice(0, 255)

    device_code = make_device_code()
    device_code_hash = hash_device_code(device_code)

    created_ip = conn |> extract_ip() |> to_string() |> String.trim() |> blank_to_nil()
    created_user_agent = conn |> extract_user_agent() |> String.slice(0, 255)

    now = DateTime.utc_now()
    expires_at = DateTime.add(now, @pairing_expires_seconds, :second)

    {pairing, user_code} =
      create_pairing_request!(
        device_code_hash,
        runner_kind,
        requested_name,
        created_ip,
        created_user_agent,
        metadata,
        expires_at
      )

    verification_url = build_verification_url(user_code)

    %{
      device_code: device_code,
      user_code: user_code,
      verification_url: verification_url,
      expires_in: @pairing_expires_seconds,
      interval: @pairing_poll_interval_seconds,
      suggested_tool_name:
        suggest_tool_name(pairing.runner_kind, pairing.requested_name, pairing.metadata || %{})
    }
  end

  @spec poll_pairing!(String.t()) :: {:ok, map()} | {:error, map()}
  def poll_pairing!(device_code) when is_binary(device_code) do
    device_code = String.trim(device_code)

    if device_code == "" do
      {:error, %{status: "error", error: "Invalid device code."}}
    else
      digest = hash_device_code(device_code)

      pairing =
        PairingRequest
        |> Ash.Query.filter(device_code_hash == ^digest)
        |> Ash.Query.sort(created_at: :desc, id: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!(authorize?: false)
        |> List.first()

      if pairing == nil do
        {:error, %{status: "error", error: "Invalid device code."}}
      else
        now = DateTime.utc_now()
        pairing = maybe_mark_expired!(pairing, now)

        case to_string(pairing.status || "") do
          "pending" ->
            {:ok, %{status: "pending"}}

          "expired" ->
            {:error, %{status: "expired", error: "Pairing code expired."}}

          "consumed" ->
            {:ok, %{status: "consumed"}}

          "approved" ->
            tool = load_tool_instance!(pairing.tool_instance_id)
            token = extract_token(tool)

            if token == "" do
              {:error, %{status: "error", error: "Pairing is approved but token is missing."}}
            else
              pairing =
                if is_nil(pairing.delivered_at) do
                  pairing
                  |> Ash.Changeset.for_update(:update, %{delivered_at: now}, authorize?: false)
                  |> Ash.update!()
                else
                  pairing
                end

              {:ok,
               %{
                 status: "approved",
                 tool_instance_id: pairing.tool_instance_id,
                 token: token
               }}
            end

          other ->
            {:error, %{status: "error", error: "Invalid pairing status: #{other}."}}
        end
      end
    end
  end

  @spec approve_pairing!(String.t(), actor :: any(), tool_name :: String.t() | nil) ::
          {:ok, %{tool_instance_id: integer(), tool_name: String.t()}} | {:error, String.t()}
  def approve_pairing!(user_code, actor, tool_name) when is_binary(user_code) do
    user_code =
      user_code
      |> to_string()
      |> String.trim()
      |> String.upcase()

    if user_code == "" do
      {:error, "user_code is required."}
    else
      pairing =
        PairingRequest
        |> Ash.Query.filter(user_code == ^user_code)
        |> Ash.Query.sort(created_at: :desc, id: :desc)
        |> Ash.Query.limit(1)
        |> Ash.read!(authorize?: false)
        |> List.first()

      if pairing == nil do
        {:error, "Pairing code not found."}
      else
        now = DateTime.utc_now()
        pairing = maybe_mark_expired!(pairing, now)

        cond do
          to_string(pairing.status || "") == "expired" ->
            {:error, "Pairing code expired."}

          to_string(pairing.status || "") != "pending" ->
            {:error, "Pairing code is not pending."}

          true ->
            suggested =
              suggest_tool_name(
                pairing.runner_kind,
                pairing.requested_name,
                pairing.metadata || %{}
              )

            final_name =
              tool_name
              |> to_string()
              |> String.trim()
              |> case do
                "" -> suggested
                value -> value
              end
              |> String.slice(0, 255)

            token = make_device_code()

            tool =
              ToolInstance
              |> Ash.Changeset.for_create(
                :create,
                %{
                  type: "outlet",
                  name: final_name,
                  config: %{},
                  secrets: %{"token" => token}
                },
                actor: actor
              )
              |> Ash.create!()

            _pairing =
              pairing
              |> Ash.Changeset.for_update(
                :update,
                %{
                  status: "approved",
                  approved_at: now,
                  approved_by_id: actor.id,
                  tool_instance_id: tool.id
                },
                authorize?: false
              )
              |> Ash.update!()

            {:ok, %{tool_instance_id: tool.id, tool_name: tool.name}}
        end
      end
    end
  end

  defp create_pairing_request!(
         device_code_hash,
         runner_kind,
         requested_name,
         created_ip,
         user_agent,
         metadata,
         expires_at
       ) do
    user_code =
      1..20
      |> Enum.reduce_while(nil, fn _i, _acc ->
        code = make_user_code()

        changeset =
          PairingRequest
          |> Ash.Changeset.for_create(
            :start,
            %{
              user_code: code,
              device_code_hash: device_code_hash,
              runner_kind: runner_kind,
              requested_name: requested_name,
              created_ip: created_ip,
              created_user_agent: user_agent,
              metadata: metadata || %{},
              status: "pending",
              expires_at: expires_at
            },
            authorize?: false
          )

        case Ash.create(changeset) do
          {:ok, pairing} -> {:halt, {pairing, code}}
          {:error, _} -> {:cont, nil}
        end
      end)

    case user_code do
      {pairing, code} -> {pairing, code}
      _ -> raise RuntimeError, "Failed to generate pairing code. Please retry."
    end
  end

  defp maybe_mark_expired!(%PairingRequest{} = pairing, now) do
    expires_at = pairing.expires_at
    status = to_string(pairing.status || "")

    expired? =
      is_struct(expires_at, DateTime) and DateTime.compare(expires_at, now) != :gt and
        status in ["pending", "approved"]

    if expired? do
      pairing
      |> Ash.Changeset.for_update(:update, %{status: "expired"}, authorize?: false)
      |> Ash.update!()
    else
      pairing
    end
  end

  defp make_device_code do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp hash_device_code(device_code) do
    device_code =
      device_code
      |> to_string()
      |> String.trim()

    :crypto.hash(:sha256, device_code)
    |> Base.encode16(case: :lower)
  end

  defp make_user_code do
    alphabet = String.graphemes(@user_code_alphabet)

    groups =
      Enum.map(1..@user_code_groups, fn _g ->
        Enum.map(1..@user_code_group_len, fn _i ->
          Enum.random(alphabet)
        end)
        |> Enum.join()
      end)

    Enum.join(groups, "-")
  end

  defp build_verification_url(user_code) do
    base = IntellectualClubWeb.Endpoint.url()
    base <> "/outlets/connect?code=" <> URI.encode_www_form(to_string(user_code || ""))
  end

  defp extract_ip(conn) do
    case conn.remote_ip do
      nil -> nil
      ip_tuple -> ip_tuple |> :inet.ntoa() |> to_string()
    end
  end

  defp extract_user_agent(conn) do
    conn
    |> Plug.Conn.get_req_header("user-agent")
    |> List.first()
    |> to_string()
    |> String.trim()
  end

  defp load_tool_instance!(nil), do: nil

  defp load_tool_instance!(tool_instance_id) when is_integer(tool_instance_id) do
    Ash.get!(ToolInstance, tool_instance_id, actor: nil, authorize?: false)
  end

  defp extract_token(nil), do: ""

  defp extract_token(tool_instance) when is_map(tool_instance) do
    secrets = Map.get(tool_instance, :secrets) || %{}
    secrets = if is_map(secrets), do: secrets, else: %{}

    (Map.get(secrets, "token") ||
       Map.get(secrets, :token) ||
       Map.get(secrets, "bearer_token") ||
       Map.get(secrets, :bearer_token) ||
       "")
    |> to_string()
    |> String.trim()
  end

  defp humanize_kind(kind) do
    kind =
      kind
      |> to_string()
      |> String.trim()
      |> String.replace("_", " ")
      |> String.replace("-", " ")
      |> String.split()
      |> Enum.map(&String.capitalize/1)
      |> Enum.join(" ")

    kind
  end

  defp suggest_tool_name(runner_kind, requested_name, metadata) do
    base =
      requested_name
      |> to_string()
      |> String.trim()
      |> case do
        "" ->
          runner_kind
          |> humanize_kind()
          |> case do
            "" -> "Outlet"
            value -> value
          end

        value ->
          value
      end

    hostname =
      metadata
      |> Map.get("hostname", Map.get(metadata, :hostname, ""))
      |> to_string()
      |> String.trim()

    base =
      if hostname != "" and not String.contains?(String.downcase(base), String.downcase(hostname)) do
        base <> " (" <> hostname <> ")"
      else
        base
      end

    String.slice(base, 0, 255)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end
end
