defmodule IntellectualClub.Accounts do
  @moduledoc """
  Accounts domain (Ash).

  Responsible for user records and authentication-related resources.
  """

  use Ash.Domain,
    extensions: [AshAdmin.Domain, AshJsonApi.Domain]

  alias IntellectualClub.Accounts.User

  @activity_touch_interval_seconds 60

  @doc false
  def touch_user_activity(%User{id: id} = actor) when is_integer(id) do
    try do
      maybe_touch_user_activity(actor)
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  def touch_user_activity(_actor), do: :ok

  resources do
    resource(IntellectualClub.Accounts.User)
    resource(IntellectualClub.Accounts.UserGroup)
    resource(IntellectualClub.Accounts.UserGroupMembership)
    resource(IntellectualClub.Accounts.UserKnowledgeBlock)
    resource(IntellectualClub.Accounts.Token)
  end

  json_api do
    routes do
      base_route "/users", IntellectualClub.Accounts.User do
        index(:read)
        get(:read)
        post(:create)
        patch(:update)
        patch(:reset_password, route: "/:id/reset-password")
        delete(:destroy)
      end

      base_route "/user-groups", IntellectualClub.Accounts.UserGroup do
        index(:admin_read)
        get(:admin_read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end

      base_route "/user-knowledge-blocks", IntellectualClub.Accounts.UserKnowledgeBlock do
        index(:read)
        get(:read)
        post(:create)
        patch(:update)
        delete(:destroy)
      end
    end
  end

  admin do
    show?(true)
    show_resources([IntellectualClub.Accounts.User, IntellectualClub.Accounts.UserGroup])
  end

  defp maybe_touch_user_activity(%User{} = actor) do
    now = DateTime.utc_now()

    with {:ok, %User{} = user} <- current_user_for_activity(actor),
         false <- activity_recent?(user.last_activity_at, now),
         {:ok, %User{}} <- update_user_activity(user, actor, now) do
      :ok
    else
      true -> :ok
      {:ok, nil} -> :ok
      {:error, _reason} = error -> error
      _other -> :ok
    end
  end

  defp current_user_for_activity(%User{id: user_id} = actor) do
    User
    |> Ash.Query.for_read(:get_current, %{id: user_id})
    |> Ash.read_one(actor: actor)
  end

  defp update_user_activity(%User{} = user, %User{} = actor, %DateTime{} = now) do
    user
    |> Ash.Changeset.for_update(
      :touch_activity,
      %{last_activity_at: DateTime.truncate(now, :microsecond)},
      actor: actor
    )
    |> Ash.update(actor: actor)
  end

  defp activity_recent?(%DateTime{} = last_activity_at, %DateTime{} = now) do
    DateTime.diff(now, last_activity_at, :second) < @activity_touch_interval_seconds
  end

  defp activity_recent?(_last_activity_at, _now), do: false
end
