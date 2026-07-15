defmodule IntellectualClub.Files.Changes.DeleteAssociatedFile do
  @moduledoc """
  Deletes a logical file referenced by a resource after the owner row is destroyed.

  The optional `strict?` flag propagates cleanup failures so the owner destroy can
  roll back. Existing callers keep best-effort cleanup by default.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Files

  @impl true
  def change(changeset, opts, _context) do
    field = Keyword.get(opts, :field, :image_file_id)
    strict? = Keyword.get(opts, :strict?, false)
    context_key = {__MODULE__, field, :file_id}

    changeset
    |> Changeset.before_action(fn changeset ->
      file_id =
        case changeset.data do
          %{^field => value} -> value
          _ -> nil
        end

      Changeset.put_context(changeset, context_key, file_id)
    end)
    |> Changeset.after_action(fn changeset, record ->
      file_id = Map.get(changeset.context, context_key)

      case delete_associated_file(file_id) do
        :ok ->
          {:ok, record}

        {:error, reason} when strict? ->
          {:error, {:delete_associated_file_failed, field, file_id, reason}}

        {:error, _reason} ->
          {:ok, record}
      end
    end)
  end

  defp delete_associated_file(file_id) when is_integer(file_id),
    do: Files.delete_file_and_maybe_payload(file_id)

  defp delete_associated_file(_file_id), do: :ok
end
