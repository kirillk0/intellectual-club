defmodule IntellectualClubWeb.Bff.ChatAccess do
  @moduledoc """
  Chat access helpers and HTTP error rendering for chat BFF route groups.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  alias IntellectualClub.Chat.Chat

  require Ash.Query

  def fetch_owned_chat(chat_id, actor) do
    case Ash.get(Chat, chat_id, actor: actor) do
      {:ok, %Chat{owner_id: owner_id} = chat} when owner_id == actor.id -> {:ok, chat}
      {:ok, %Chat{}} -> {:error, :forbidden}
      {:ok, nil} -> {:error, :not_found}
      {:error, %Ash.Error.Query.NotFound{}} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, %Ash.Error.Invalid{} = error} -> {:error, normalize_invalid_access_error(error)}
      {:error, error} -> {:error, error}
    end
  end

  def fetch_readable_chat(chat_id, actor) do
    Chat
    |> Ash.Query.filter(id == ^chat_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.load([:can_edit, :shared_incoming, :shared_outgoing], strict?: true)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, [%Chat{} = chat]} -> {:ok, chat}
      {:ok, []} -> {:error, :not_found}
      {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
      {:error, error} -> {:error, error}
    end
  end

  def fetch_readable_chat_for_idle(chat_id, actor) do
    with {:ok, %Chat{} = chat} <- fetch_readable_chat(chat_id, actor) do
      {:ok, Ash.load!(chat, [:last_message], actor: actor)}
    end
  end

  def render_error(conn, {:validation, message}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: message})
  end

  def render_error(conn, :forbidden) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "Forbidden"})
  end

  def render_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found"})
  end

  def render_error(conn, %Ash.Error.Forbidden{}) do
    render_error(conn, :forbidden)
  end

  def render_error(conn, %Ash.Error.Query.NotFound{}) do
    render_error(conn, :not_found)
  end

  def render_error(conn, %Ash.Error.Invalid{} = error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: Exception.message(error)})
  end

  def render_error(conn, error) when is_binary(error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: error})
  end

  def render_error(conn, error) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: Exception.message(error)})
  end

  defp normalize_invalid_access_error(%Ash.Error.Invalid{errors: errors} = error) do
    cond do
      Enum.any?(errors, &match?(%Ash.Error.Forbidden{}, &1)) ->
        :forbidden

      Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) ->
        :not_found

      true ->
        error
    end
  end
end
