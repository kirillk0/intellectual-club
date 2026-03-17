defmodule IntellectualClub.Accounts.Validations.PreventSelfAdminDemotion do
  @moduledoc """
  Prevents an administrator from removing their own admin access.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    actor_id = actor_id(context)
    target_id = changeset.data.id
    next_is_admin = Ash.Changeset.get_attribute(changeset, :is_admin)

    if is_integer(actor_id) and is_integer(target_id) and actor_id == target_id and
         next_is_admin == false do
      {:error, field: :is_admin, message: "cannot remove admin access from yourself"}
    else
      :ok
    end
  end

  defp actor_id(%{actor: %{id: id}}) when is_integer(id), do: id
  defp actor_id(_context), do: nil
end
