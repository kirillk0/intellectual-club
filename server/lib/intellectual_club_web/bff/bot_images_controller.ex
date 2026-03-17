defmodule IntellectualClubWeb.Bff.BotImagesController do
  @moduledoc """
  Authenticated image transport for bots.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Bots.Bot
  alias IntellectualClubWeb.Bff.Helpers
  alias IntellectualClubWeb.Bff.ImageControllerHelpers

  def show(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         bot_id when is_integer(bot_id) <- Helpers.parse_optional_integer(id),
         {:ok, bot} <- Ash.get(Bot, bot_id, actor: actor) do
      ImageControllerHelpers.send_image(conn, bot.image_file_id)
    else
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        ImageControllerHelpers.render_not_found(conn)

      {:error, conn} ->
        conn

      _other ->
        ImageControllerHelpers.render_not_found(conn)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         bot_id when is_integer(bot_id) <- Helpers.parse_optional_integer(id),
         {:ok, bot} <- Ash.get(Bot, bot_id, actor: actor),
         {:ok, image_params} <-
           ImageControllerHelpers.validate_image_upload(Map.get(params, "file")) do
      case bot
           |> Ash.Changeset.for_update(:set_image, image_params, actor: actor)
           |> Ash.update(actor: actor) do
        {:ok, updated} ->
          updated = Ash.load!(updated, :image, actor: actor)
          json(conn, %{image: updated.image})

        {:error, error} ->
          ImageControllerHelpers.render_action_error(conn, error)
      end
    else
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        ImageControllerHelpers.render_not_found(conn)

      {:error, message} when is_binary(message) ->
        ImageControllerHelpers.render_validation_error(conn, message)

      {:error, conn} ->
        conn

      _other ->
        ImageControllerHelpers.render_not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         bot_id when is_integer(bot_id) <- Helpers.parse_optional_integer(id),
         {:ok, bot} <- Ash.get(Bot, bot_id, actor: actor) do
      case bot
           |> Ash.Changeset.for_update(:clear_image, %{}, actor: actor)
           |> Ash.update(actor: actor) do
        {:ok, _updated} ->
          json(conn, %{image: nil})

        {:error, error} ->
          ImageControllerHelpers.render_action_error(conn, error)
      end
    else
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        ImageControllerHelpers.render_not_found(conn)

      {:error, conn} ->
        conn

      _other ->
        ImageControllerHelpers.render_not_found(conn)
    end
  end
end
