defmodule IntellectualClubWeb.Bff.AdminUsersController do
  @moduledoc """
  Administrative CRUD endpoints for users inside the SPA.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Accounts.User
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  require Ash.Query

  def index(conn, _params) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         {:ok, users} <- list_users(actor) do
      json(conn, %{users: Enum.map(users, &Serializer.admin_user/1)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_action_error(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         user_id when is_integer(user_id) <- Helpers.parse_optional_integer(id),
         {:ok, user} <- fetch_user(user_id, actor) do
      json(conn, %{user: Serializer.admin_user(user)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      _other ->
        render_not_found(conn)
    end
  end

  def create(conn, params) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         {:ok, user} <- create_user(params, actor) do
      conn
      |> put_status(:created)
      |> json(%{user: Serializer.admin_user(user)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_action_error(conn, error)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         user_id when is_integer(user_id) <- Helpers.parse_optional_integer(id),
         {:ok, user} <- fetch_user(user_id, actor),
         {:ok, updated_user} <- update_user(user, params, actor) do
      json(conn, %{user: Serializer.admin_user(updated_user)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_action_error(conn, error)

      _other ->
        render_not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         user_id when is_integer(user_id) <- Helpers.parse_optional_integer(id),
         {:ok, user} <- fetch_user(user_id, actor),
         :ok <- destroy_user(user, actor) do
      json(conn, %{detail: "ok"})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_action_error(conn, error)

      _other ->
        render_not_found(conn)
    end
  end

  def reset_password(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         user_id when is_integer(user_id) <- Helpers.parse_optional_integer(id),
         {:ok, user} <- fetch_user(user_id, actor),
         {:ok, updated_user} <- reset_user_password(user, params, actor) do
      json(conn, %{user: Serializer.admin_user(updated_user)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_action_error(conn, error)

      _other ->
        render_not_found(conn)
    end
  end

  defp list_users(actor) do
    User
    |> Ash.Query.sort(username: :asc, id: :asc)
    |> Ash.Query.load(:groups)
    |> Ash.read(actor: actor)
  end

  defp fetch_user(user_id, actor) when is_integer(user_id) do
    case Ash.get(User, user_id, actor: actor, load: [:groups], strict?: true) do
      {:ok, %User{} = user} -> {:ok, user}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_user(_user_id, _actor), do: {:error, :not_found}

  defp create_user(params, actor) do
    payload =
      %{
        username: params |> Map.get("username", "") |> to_string(),
        is_admin: Helpers.parse_boolean(Map.get(params, "is_admin"), false),
        password: params |> Map.get("password", "") |> to_string(),
        password_confirmation: params |> Map.get("password_confirmation", "") |> to_string()
      }
      |> maybe_put_groups(params)

    User
    |> Ash.Changeset.for_create(:create, payload, actor: actor)
    |> Ash.create()
  end

  defp update_user(%User{} = user, params, actor) do
    payload =
      %{
        username: params |> Map.get("username", "") |> to_string(),
        is_admin: Helpers.parse_boolean(Map.get(params, "is_admin"), false)
      }
      |> maybe_put_groups(params)

    user
    |> Ash.Changeset.for_update(:update, payload, actor: actor)
    |> Ash.update()
  end

  defp reset_user_password(%User{} = user, params, actor) do
    payload = %{
      password: params |> Map.get("password", "") |> to_string(),
      password_confirmation: params |> Map.get("password_confirmation", "") |> to_string()
    }

    user
    |> Ash.Changeset.for_update(:reset_password, payload, actor: actor)
    |> Ash.update()
  end

  defp destroy_user(%User{} = user, actor) do
    case user
         |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
         |> Ash.destroy() do
      :ok -> :ok
      {:ok, _destroyed_user} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp render_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found"})
  end

  defp render_action_error(conn, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}) do
    render_not_found(conn)
  end

  defp render_action_error(conn, %Ash.Error.Invalid{} = error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{detail: "Validation failed", errors: invalid_error_map(error)})
  end

  defp render_action_error(conn, %Ash.Error.Forbidden{}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Forbidden"})
  end

  defp render_action_error(conn, :not_found) do
    render_not_found(conn)
  end

  defp render_action_error(conn, error) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: normalize_error_message(error)})
  end

  defp invalid_error_map(%Ash.Error.Invalid{} = error) do
    error
    |> Map.get(:errors, [])
    |> List.wrap()
    |> Enum.reject(&match?(%Ash.Error.Query.NotFound{}, &1))
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

  defp map_error_field(nil), do: "_form"
  defp map_error_field(field) when is_atom(field), do: Atom.to_string(field)
  defp map_error_field(field) when is_binary(field), do: field
  defp map_error_field(_field), do: "_form"

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

  defp normalize_error_message(error) when is_exception(error) do
    error
    |> Exception.message()
    |> String.trim()
  end

  defp normalize_error_message(_error), do: "Request failed."

  defp maybe_put_groups(payload, params) do
    case extract_group_ids(params) do
      nil -> payload
      group_ids -> Map.put(payload, :groups, group_ids)
    end
  end

  defp extract_group_ids(params) do
    cond do
      Map.has_key?(params, "group_ids") ->
        Helpers.parse_integer_list(Map.get(params, "group_ids"))

      Map.has_key?(params, "groups") ->
        Helpers.parse_integer_list(Map.get(params, "groups"))

      true ->
        nil
    end
  end
end
