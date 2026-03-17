defmodule IntellectualClub.Llm.Auth.OpenAIOAuth do
  @moduledoc """
  OpenAI OAuth refresh-token flow.

  This module exchanges a refresh token for an access token using:
  `POST https://auth.openai.com/oauth/token` with `grant_type=refresh_token`.
  """

  import Ecto.Query, only: [from: 2]

  alias IntellectualClub.Db

  @cache_table :ic_openai_oauth_token_cache
  @default_lock_timeout_ms 15_000
  @default_lock_stale_after_ms 60_000

  @spec get_access_token(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def get_access_token(refresh_token, opts \\ []) when is_binary(refresh_token) do
    provider_id = Keyword.get(opts, :provider_id)

    ensure_cache_table!()

    cache_key = cache_key(provider_id, refresh_token)
    now = System.system_time(:second)

    case lookup_cached_token(cache_key, now) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        refresh_token_to_use = resolve_refresh_token(refresh_token, provider_id)

        if blank?(refresh_token_to_use) do
          {:error, "Refresh token is not set"}
        else
          maybe_with_lock(provider_id, cache_key, fn ->
            refresh_and_cache(refresh_token_to_use, cache_key, now, provider_id: provider_id)
          end)
        end
    end
  end

  defp lookup_cached_token(cache_key, now) do
    early_seconds = refresh_early_seconds()

    case :ets.lookup(@cache_table, cache_key) do
      [{^cache_key, token, expires_at, _refresh_token}]
      when is_binary(token) and is_integer(expires_at) ->
        if now + early_seconds < expires_at do
          {:ok, token}
        else
          :miss
        end

      [{^cache_key, token, expires_at}] when is_binary(token) and is_integer(expires_at) ->
        if now + early_seconds < expires_at do
          {:ok, token}
        else
          :miss
        end

      _ ->
        :miss
    end
  end

  defp maybe_with_lock(provider_id, cache_key, fun)
       when is_function(fun, 0) do
    if is_integer(provider_id) do
      lock_key = {:lock, cache_key}

      case try_acquire_lock(lock_key) do
        :acquired ->
          try do
            fun.()
          after
            release_lock(lock_key)
          end

        :busy ->
          case wait_for_refresh(cache_key, lock_key) do
            {:ok, token} ->
              {:ok, token}

            :timeout ->
              fun.()
          end
      end
    else
      fun.()
    end
  end

  defp refresh_and_cache(refresh_token, cache_key, now, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    client_id = client_id()
    token_url = token_url()

    request_opts =
      [
        url: token_url,
        method: :post,
        form: [
          {"grant_type", "refresh_token"},
          {"refresh_token", refresh_token},
          {"client_id", client_id}
        ],
        connect_options: [timeout: connect_timeout_ms()],
        receive_timeout: request_timeout_ms()
      ]
      |> Keyword.merge(req_options())

    response =
      try do
        {:ok, Req.request!(request_opts)}
      rescue
        exception ->
          {:error, Exception.message(exception)}
      catch
        :exit, reason ->
          {:error, Exception.format_exit(reason)}
      end

    case response do
      {:ok, %{status: status, body: body}}
      when is_integer(status) and status >= 200 and status < 300 ->
        with {:ok, %{"access_token" => access_token} = data} <- normalize_json(body),
             true <- is_binary(access_token) and String.trim(access_token) != "" do
          expires_in = normalize_expires_in(Map.get(data, "expires_in"))
          expires_at = now + expires_in
          token = String.trim(access_token)
          new_refresh_token = normalize_optional_token(Map.get(data, "refresh_token"))

          refresh_token_for_cache =
            if blank?(new_refresh_token) do
              refresh_token
            else
              new_refresh_token
            end

          :ets.insert(@cache_table, {cache_key, token, expires_at, refresh_token_for_cache})

          if is_integer(provider_id) and is_binary(new_refresh_token) and
               not blank?(new_refresh_token) do
            _ = persist_refresh_token(provider_id, new_refresh_token)
          end

          {:ok, token}
        else
          _ ->
            {:error, "OAuth token refresh returned an unexpected response"}
        end

      {:ok, %{status: status, body: body}} when is_integer(status) ->
        if refresh_token_reused?(body) and is_integer(provider_id) do
          handle_refresh_token_reused(cache_key, provider_id, refresh_token, now)
        else
          message = extract_error_message(body)
          {:error, "OAuth token refresh failed (status #{status}): #{message}"}
        end

      {:error, reason} ->
        {:error, "OAuth token refresh failed: #{reason}"}
    end
  end

  defp handle_refresh_token_reused(cache_key, provider_id, refresh_token, _now) do
    # Another process likely refreshed and rotated the refresh token.
    now = System.system_time(:second)

    case lookup_cached_token(cache_key, now) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        latest = load_refresh_token(provider_id)

        cond do
          blank?(latest) ->
            {:error, "OAuth refresh token was already used and no new token is available"}

          String.trim(latest) == String.trim(refresh_token) ->
            {:error, "OAuth refresh token was already used and no new token is available"}

          true ->
            refresh_and_cache(String.trim(latest), cache_key, now, provider_id: provider_id)
        end
    end
  end

  defp refresh_token_reused?(body) do
    case normalize_json(body) do
      {:ok, %{"error" => %{"code" => "refresh_token_reused"}}} ->
        true

      {:ok, %{"error" => %{"code" => code}}} when is_binary(code) ->
        String.trim(code) == "refresh_token_reused"

      _ ->
        false
    end
  end

  defp extract_error_message(body) do
    case normalize_json(body) do
      {:ok, %{"error" => %{"message" => message, "code" => code}}}
      when is_binary(message) and message != "" and is_binary(code) and code != "" ->
        "#{code}: #{message}"

      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) and message != "" ->
        message

      {:ok, %{"error_description" => desc}} when is_binary(desc) and desc != "" ->
        desc

      {:ok, %{"error" => error}} when is_binary(error) and error != "" ->
        error

      _ ->
        safe_string(body)
    end
  end

  defp normalize_json(body) when is_map(body) do
    {:ok, body |> stringify_keys()}
  end

  defp normalize_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, stringify_keys(decoded)}
      _ -> :error
    end
  end

  defp normalize_json(_body), do: :error

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp normalize_expires_in(value) when is_integer(value) and value > 0, do: value

  defp normalize_expires_in(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {int, _rest} when int > 0 -> int
      _ -> default_expires_in_seconds()
    end
  end

  defp normalize_expires_in(_value), do: default_expires_in_seconds()

  defp default_expires_in_seconds do
    3600
  end

  defp normalize_optional_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      token -> token
    end
  end

  defp normalize_optional_token(_value), do: nil

  defp resolve_refresh_token(refresh_token, provider_id) do
    if is_integer(provider_id) do
      case load_refresh_token(provider_id) do
        token when is_binary(token) ->
          token = String.trim(token)
          if token == "", do: String.trim(refresh_token), else: token

        _ ->
          String.trim(refresh_token)
      end
    else
      String.trim(refresh_token)
    end
  end

  defp load_refresh_token(provider_id) when is_integer(provider_id) do
    repo = Db.repo()

    repo.one(
      from(p in "llm_providers",
        where: p.id == ^provider_id,
        select: p.oauth_refresh_token
      )
    )
  rescue
    _exception -> nil
  catch
    :exit, _reason -> nil
  end

  defp persist_refresh_token(provider_id, refresh_token)
       when is_integer(provider_id) and is_binary(refresh_token) do
    repo = Db.repo()
    now = DateTime.utc_now()
    token = String.trim(refresh_token)

    if token == "" do
      {:error, :blank}
    else
      {count, _} =
        from(p in "llm_providers", where: p.id == ^provider_id)
        |> repo.update_all(set: [oauth_refresh_token: token, updated_at: now])

      if count > 0, do: :ok, else: {:error, :not_found}
    end
  rescue
    exception ->
      {:error, Exception.message(exception)}
  catch
    :exit, reason ->
      {:error, Exception.format_exit(reason)}
  end

  defp refresh_early_seconds do
    Application.get_env(:intellectual_club, :openai_oauth, [])
    |> Keyword.get(:refresh_early_seconds, 300)
  end

  defp connect_timeout_ms do
    Application.get_env(:intellectual_club, :openai_oauth, [])
    |> Keyword.get(:connect_timeout_ms, 10_000)
  end

  defp request_timeout_ms do
    Application.get_env(:intellectual_club, :openai_oauth, [])
    |> Keyword.get(:request_timeout_ms, 30_000)
  end

  defp client_id do
    Application.get_env(:intellectual_club, :openai_oauth, [])
    |> Keyword.get(:client_id, "app_EMoamEEZ73f0CkXaXp7hrann")
  end

  defp token_url do
    Application.get_env(:intellectual_club, :openai_oauth, [])
    |> Keyword.get(:token_url, "https://auth.openai.com/oauth/token")
  end

  defp req_options do
    Application.get_env(:intellectual_club, :openai_oauth_req_options, [])
  end

  defp cache_key(provider_id, refresh_token) do
    if is_integer(provider_id) do
      {:openai_oauth, provider_id}
    else
      {:openai_oauth, token_hash(refresh_token)}
    end
  end

  defp token_hash(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  defp token_hash(_token), do: "unknown"

  defp try_acquire_lock(lock_key) do
    started_ms = System.monotonic_time(:millisecond)

    if :ets.insert_new(@cache_table, {lock_key, started_ms}) do
      :acquired
    else
      :busy
    end
  end

  defp release_lock(lock_key) do
    :ets.delete(@cache_table, lock_key)
  end

  defp wait_for_refresh(cache_key, lock_key) do
    deadline_ms = System.monotonic_time(:millisecond) + lock_timeout_ms()
    do_wait_for_refresh(cache_key, lock_key, deadline_ms)
  end

  defp do_wait_for_refresh(cache_key, lock_key, deadline_ms) do
    now = System.system_time(:second)

    case lookup_cached_token(cache_key, now) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        cond do
          System.monotonic_time(:millisecond) >= deadline_ms ->
            :timeout

          lock_stale?(lock_key) ->
            :timeout

          true ->
            Process.sleep(50)
            do_wait_for_refresh(cache_key, lock_key, deadline_ms)
        end
    end
  end

  defp lock_stale?(lock_key) do
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, lock_key) do
      [{^lock_key, started_ms}] when is_integer(started_ms) ->
        if now_ms - started_ms > lock_stale_after_ms() do
          :ets.delete(@cache_table, lock_key)
          true
        else
          false
        end

      _ ->
        false
    end
  end

  defp lock_timeout_ms do
    Application.get_env(:intellectual_club, :openai_oauth, [])
    |> Keyword.get(:lock_timeout_ms, @default_lock_timeout_ms)
  end

  defp lock_stale_after_ms do
    Application.get_env(:intellectual_club, :openai_oauth, [])
    |> Keyword.get(:lock_stale_after_ms, @default_lock_stale_after_ms)
  end

  defp ensure_cache_table! do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError ->
            :ok
        end

        :ok

      _tid ->
        :ok
    end
  end

  defp safe_string(value) when is_binary(value), do: value
  defp safe_string(value), do: inspect(value)

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true
end
