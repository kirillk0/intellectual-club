defmodule IntellectualClubWeb.Bff.Helpers do
  @moduledoc """
  Small helper utilities for the BFF JSON API.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias IntellectualClub.Accounts.User
  alias IntellectualClubWeb.ErrorJSON

  use Gettext, backend: IntellectualClubWeb.Gettext

  def actor(conn) do
    Ash.PlugHelpers.get_actor(conn) || conn.assigns[:current_user]
  end

  def current_user(conn) do
    with %{id: user_id} = actor when is_integer(user_id) <- actor(conn),
         {:ok, %User{} = user} <-
           User
           |> Ash.Query.for_read(:get_current, %{id: user_id})
           |> Ash.read_one(actor: actor) do
      {:ok, user}
    else
      _other -> {:error, :unauthorized}
    end
  end

  def require_actor(conn) do
    case current_user(conn) do
      {:error, _reason} ->
        conn =
          conn
          |> put_status(:unauthorized)
          |> put_view(ErrorJSON)
          |> json(%{error: gettext("Unauthorized")})
          |> halt()

        {:error, conn}

      {:ok, user} ->
        {:ok, user}
    end
  end

  def require_admin(conn) do
    with {:ok, actor} <- require_actor(conn) do
      if Map.get(actor, :is_admin) do
        {:ok, actor}
      else
        conn =
          conn
          |> put_status(:forbidden)
          |> put_view(ErrorJSON)
          |> json(%{error: gettext("Forbidden")})
          |> halt()

        {:error, conn}
      end
    end
  end

  def parse_optional_integer(nil), do: nil
  def parse_optional_integer(""), do: nil

  def parse_optional_integer(value) when is_integer(value), do: value

  def parse_optional_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  def parse_optional_integer(_value), do: nil

  def parse_integer_list(nil), do: nil

  def parse_integer_list(values) when is_list(values) do
    values
    |> Enum.map(&parse_optional_integer/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def parse_integer_list(value) do
    value
    |> parse_optional_integer()
    |> case do
      nil -> []
      parsed -> [parsed]
    end
  end

  def parse_boolean(value, default \\ false)

  def parse_boolean(value, _default) when is_boolean(value), do: value
  def parse_boolean(nil, default), do: default

  def parse_boolean(value, default) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> true
      "1" -> true
      "false" -> false
      "0" -> false
      _other -> default
    end
  end

  def parse_boolean(_value, default), do: default

  def ensure_integer!(value, _field_name) when is_integer(value), do: value

  def ensure_integer!(value, field_name) do
    raise ArgumentError, "#{field_name} must be an integer, got: #{inspect(value)}"
  end
end
