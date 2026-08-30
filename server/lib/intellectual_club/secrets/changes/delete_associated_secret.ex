defmodule IntellectualClub.Secrets.Changes.DeleteAssociatedSecret do
  @moduledoc """
  Deletes the managed secret owned by an attachment after the attachment is destroyed.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Secrets.Secret

  @impl true
  def change(changeset, opts, _context) do
    field = Keyword.get(opts, :field, :secret_id)
    strict? = Keyword.get(opts, :strict?, true)
    context_key = {__MODULE__, field, :secret_id}

    changeset
    |> Changeset.before_action(fn changeset ->
      secret_id =
        case changeset.data do
          %{^field => value} -> value
          _other -> nil
        end

      Changeset.put_context(changeset, context_key, secret_id)
    end)
    |> Changeset.after_action(fn changeset, record ->
      secret_id = Map.get(changeset.context, context_key)

      case delete_secret(secret_id) do
        :ok ->
          {:ok, record}

        {:error, reason} when strict? ->
          {:error, {:delete_associated_secret_failed, field, secret_id, reason}}

        {:error, _reason} ->
          {:ok, record}
      end
    end)
  end

  defp delete_secret(secret_id) when is_integer(secret_id) do
    case Ash.get(Secret, secret_id, authorize?: false) do
      {:ok, secret} ->
        case Ash.destroy(secret, authorize?: false) do
          :ok -> :ok
          {:ok, _secret} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_secret(_secret_id), do: :ok
end
