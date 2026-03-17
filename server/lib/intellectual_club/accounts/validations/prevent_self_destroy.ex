defmodule IntellectualClub.Accounts.Validations.PreventSelfDestroy do
  @moduledoc """
  Prevents an administrator from deleting their own account.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    actor_id = actor_id(context)
    target_id = changeset.data.id

    if is_integer(actor_id) and is_integer(target_id) and actor_id == target_id do
      {:error, message: "cannot delete yourself"}
    else
      :ok
    end
  end

  defp actor_id(%{actor: %{id: id}}) when is_integer(id), do: id
  defp actor_id(_context), do: nil
end
