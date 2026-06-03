defmodule IntellectualClubWeb.Bff.MeController do
  @moduledoc """
  Returns and updates current authenticated user settings for the SPA.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Sharing
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  def show(conn, _params) do
    with {:ok, user} <- Helpers.require_actor(conn) do
      json(conn, %{user: Serializer.user(user)})
    end
  end

  def update(conn, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, updated_user} <- update_user_settings(actor, params, actor) do
      json(conn, %{user: Serializer.user(updated_user)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, {:validation, field_errors}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{detail: gettext("Validation failed"), errors: field_errors})

      {:error, _other} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{detail: gettext("Failed to save user settings.")})
    end
  end

  def groups(conn, _params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, groups} <- Sharing.list_actor_groups(actor) do
      json(conn, %{groups: Enum.map(groups, &Serializer.user_group_summary/1)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, _error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: gettext("Failed to load groups.")})
    end
  end

  def change_password(conn, params) do
    new_password = params |> Map.get("new_password", "") |> to_string()

    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, user} <- fetch_user(actor),
         {:ok, updated_user} <- change_user_password(user, params, actor) do
      conn
      |> refresh_session(updated_user.username, new_password)
      |> json(%{detail: "ok"})
    else
      {:error, {:validation, field_errors}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{detail: gettext("Validation failed"), errors: field_errors})

      {:error, _other} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{detail: gettext("Failed to change password.")})
    end
  end

  defp fetch_user(%{id: user_id}) when is_integer(user_id) do
    case Ash.get(User, user_id, authorize?: false) do
      {:ok, %User{} = user} -> {:ok, user}
      _other -> {:error, :not_found}
    end
  end

  defp fetch_user(_actor), do: {:error, :not_found}

  defp update_user_settings(%User{} = user, params, actor) do
    payload = %{
      preferred_locale:
        if(Map.has_key?(params, "preferred_locale"),
          do: normalize_preferred_locale(Map.get(params, "preferred_locale")),
          else: user.preferred_locale
        ),
      preferred_theme:
        if(Map.has_key?(params, "preferred_theme"),
          do: normalize_preferred_theme(Map.get(params, "preferred_theme")),
          else: user.preferred_theme || "system"
        )
    }

    user
    |> Ash.Changeset.for_update(:update_settings, payload, actor: actor)
    |> Ash.update()
    |> case do
      {:ok, updated_user} ->
        {:ok, updated_user}

      {:error, %Ash.Error.Invalid{} = error} ->
        {:error, {:validation, invalid_error_map(error)}}

      {:error, _error} = error ->
        error
    end
  end

  defp normalize_preferred_locale(nil), do: nil
  defp normalize_preferred_locale(""), do: nil

  defp normalize_preferred_locale(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_preferred_locale(value), do: value

  defp normalize_preferred_theme(nil), do: "system"
  defp normalize_preferred_theme(""), do: "system"

  defp normalize_preferred_theme(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_preferred_theme(value), do: value

  defp change_user_password(%User{} = user, params, actor) do
    payload = %{
      current_password: params |> Map.get("current_password", "") |> to_string(),
      password: params |> Map.get("new_password", "") |> to_string(),
      password_confirmation: params |> Map.get("new_password_confirm", "") |> to_string()
    }

    user
    |> Ash.Changeset.for_update(:change_password, payload, actor: actor)
    |> Ash.update()
    |> case do
      {:ok, updated_user} ->
        {:ok, updated_user}

      {:error, %Ash.Error.Invalid{} = error} ->
        {:error, {:validation, invalid_error_map(error)}}

      {:error, _error} = error ->
        error
    end
  end

  defp invalid_error_map(%Ash.Error.Invalid{} = error) do
    error
    |> Map.get(:errors, [])
    |> List.wrap()
    |> Enum.reduce(%{}, fn entry, acc ->
      key = map_error_field(Map.get(entry, :field))
      message = normalize_error_message(entry)

      if message == "" do
        acc
      else
        Map.update(acc, key, [message], fn existing -> Enum.uniq(existing ++ [message]) end)
      end
    end)
  end

  defp map_error_field(:password), do: "new_password"
  defp map_error_field(:password_confirmation), do: "new_password_confirm"
  defp map_error_field(:current_password), do: "current_password"
  defp map_error_field(:preferred_locale), do: "preferred_locale"
  defp map_error_field(:preferred_theme), do: "preferred_theme"
  defp map_error_field(nil), do: "_form"

  defp map_error_field(field) when is_atom(field), do: Atom.to_string(field)
  defp map_error_field(field) when is_binary(field), do: field
  defp map_error_field(_field), do: "_form"

  defp normalize_error_message(%AshAuthentication.Errors.AuthenticationFailed{
         field: :current_password
       }),
       do: gettext("Current password is incorrect.")

  defp normalize_error_message(%{message: message}) when is_binary(message) do
    message
    |> String.trim()
    |> then(fn trimmed ->
      cond do
        trimmed == "" -> ""
        String.ends_with?(trimmed, ".") -> trimmed
        true -> trimmed <> "."
      end
    end)
  end

  defp normalize_error_message(entry) do
    entry
    |> Exception.message()
    |> String.trim()
  end

  defp refresh_session(conn, username, password)
       when is_binary(username) and username != "" and is_binary(password) and password != "" do
    strategy = AshAuthentication.Info.strategy!(User, :password)

    case AshAuthentication.Strategy.action(strategy, :sign_in, %{
           "username" => username,
           "password" => password
         }) do
      {:ok, signed_in_user} ->
        AshAuthentication.Plug.Helpers.store_in_session(conn, signed_in_user)

      _other ->
        conn
    end
  end

  defp refresh_session(conn, _username, _password), do: conn
end
