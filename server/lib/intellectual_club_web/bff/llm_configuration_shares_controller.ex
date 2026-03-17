defmodule IntellectualClubWeb.Bff.LlmConfigurationSharesController do
  @moduledoc """
  Owner-only sharing endpoints for LLM configuration group sharing.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Sharing
  alias IntellectualClubWeb.Bff.Helpers

  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, configuration_id} <- parse_resource_id(id),
         {:ok, state} <- Sharing.get_llm_configuration_share_state(configuration_id, actor) do
      json(conn, state)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_error(conn, error)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, configuration_id} <- parse_resource_id(id),
         {:ok, group_ids} <- parse_group_ids(params),
         {:ok, state} <-
           Sharing.replace_llm_configuration_share_state(configuration_id, group_ids, actor) do
      json(conn, state)
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, error} ->
        render_error(conn, error)
    end
  end

  defp parse_resource_id(id) do
    case Helpers.parse_optional_integer(id) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, :not_found}
    end
  end

  defp parse_group_ids(params) do
    case Map.get(params, "group_ids", []) do
      ids when is_list(ids) ->
        if Enum.all?(ids, &valid_integer_like?/1) do
          {:ok, Helpers.parse_integer_list(ids)}
        else
          {:error, {:validation, "group_ids must contain integers."}}
        end

      _other ->
        {:error, {:validation, "group_ids must be a list."}}
    end
  end

  defp valid_integer_like?(value) when is_integer(value), do: true

  defp valid_integer_like?(value) when is_binary(value) do
    match?({number, ""} when number > 0, Integer.parse(value))
  end

  defp valid_integer_like?(_value), do: false

  defp render_error(conn, {:validation, message}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end

  defp render_error(conn, :forbidden) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Forbidden"})
  end

  defp render_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found"})
  end

  defp render_error(conn, %Ash.Error.Forbidden{}) do
    render_error(conn, :forbidden)
  end

  defp render_error(conn, %Ash.Error.Invalid{} = error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Exception.message(error)})
  end

  defp render_error(conn, error) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: Exception.message(error)})
  end
end
