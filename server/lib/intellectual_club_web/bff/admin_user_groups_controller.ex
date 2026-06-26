defmodule IntellectualClubWeb.Bff.AdminUserGroupsController do
  @moduledoc """
  Administrative CRUD endpoints for user groups inside the SPA.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Accounts.UserGroup
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.Serializer

  def index(conn, _params) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         {:ok, groups} <- list_groups(actor) do
      json(conn, %{groups: Enum.map(groups, &Serializer.admin_user_group/1)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_action_error(conn, error)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         group_id when is_integer(group_id) <- Helpers.parse_optional_integer(id),
         {:ok, group} <- fetch_group(group_id, actor) do
      json(conn, %{group: Serializer.admin_user_group(group)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      _other ->
        render_not_found(conn)
    end
  end

  def create(conn, params) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         {:ok, group} <- create_group(params, actor) do
      conn
      |> put_status(:created)
      |> json(%{group: Serializer.admin_user_group(group)})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_action_error(conn, error)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_admin(conn),
         group_id when is_integer(group_id) <- Helpers.parse_optional_integer(id),
         {:ok, group} <- fetch_group(group_id, actor),
         {:ok, updated_group} <- update_group(group, params, actor) do
      json(conn, %{group: Serializer.admin_user_group(updated_group)})
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
         group_id when is_integer(group_id) <- Helpers.parse_optional_integer(id),
         {:ok, group} <- fetch_group(group_id, actor),
         :ok <- destroy_group(group, actor) do
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

  defp list_groups(actor) do
    UserGroup
    |> Ash.Query.sort(name: :asc, id: :asc)
    |> Ash.Query.load(:users)
    |> Ash.read(actor: actor)
  end

  defp fetch_group(group_id, actor) when is_integer(group_id) do
    case Ash.get(UserGroup, group_id, actor: actor, load: [:users], strict?: true) do
      {:ok, %UserGroup{} = group} -> {:ok, group}
      {:ok, nil} -> {:error, :not_found}
      {:error, error} -> {:error, error}
    end
  end

  defp create_group(params, actor) do
    payload =
      %{
        name: params |> Map.get("name", "") |> to_string()
      }
      |> maybe_put_users(params)

    UserGroup
    |> Ash.Changeset.for_create(:create, payload, actor: actor)
    |> Ash.create()
  end

  defp update_group(%UserGroup{} = group, params, actor) do
    payload =
      %{
        name: params |> Map.get("name", "") |> to_string()
      }
      |> maybe_put_users(params)

    group
    |> Ash.Changeset.for_update(:update, payload, actor: actor)
    |> Ash.update()
  end

  defp destroy_group(%UserGroup{} = group, actor) do
    case group
         |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
         |> Ash.destroy() do
      :ok -> :ok
      {:ok, _destroyed_group} -> :ok
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

  defp maybe_put_users(payload, params) do
    case extract_user_ids(params) do
      nil -> payload
      user_ids -> Map.put(payload, :users, user_ids)
    end
  end

  defp extract_user_ids(params) do
    cond do
      Map.has_key?(params, "user_ids") -> Helpers.parse_integer_list(Map.get(params, "user_ids"))
      Map.has_key?(params, "users") -> Helpers.parse_integer_list(Map.get(params, "users"))
      true -> nil
    end
  end
end
