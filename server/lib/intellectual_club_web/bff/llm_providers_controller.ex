defmodule IntellectualClubWeb.Bff.LlmProvidersController do
  @moduledoc """
  BFF endpoints for LLM provider helpers.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Llm.LlmProvider
  alias IntellectualClub.Llm.ModelCatalog
  alias IntellectualClubWeb.Bff.Helpers

  def models(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         {:ok, provider_id} <- parse_id(id),
         {:ok, provider} <- Ash.get(LlmProvider, provider_id, actor: actor),
         {:ok, provider} <- ensure_provider_access(provider, actor),
         {:ok, models} <- ModelCatalog.list_models(provider) do
      json(conn, %{models: models})
    else
      {:error, %Plug.Conn{} = conn} ->
        conn

      {:error, :invalid_id} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Provider not found."})

      {:error, %Ash.Error.Query.NotFound{}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Provider not found."})

      {:error, %Ash.Error.Forbidden{}} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Forbidden"})

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Forbidden"})

      {:error, message} when is_binary(message) ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: message})

      {:error, _error} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to load provider models."})
    end
  end

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :invalid_id}
    end
  end

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_id(_value), do: {:error, :invalid_id}

  defp ensure_provider_access(%LlmProvider{owner_id: owner_id} = provider, %{id: actor_id})
       when is_integer(owner_id) and owner_id == actor_id do
    {:ok, provider}
  end

  defp ensure_provider_access(%LlmProvider{}, _actor), do: {:error, :forbidden}
end
