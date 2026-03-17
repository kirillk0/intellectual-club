defmodule IntellectualClub.Files.Changes.DeleteAssociatedFile do
  @moduledoc """
  Deletes a logical file referenced by a resource after the owner row is destroyed.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Files

  @impl true
  def change(changeset, opts, _context) do
    field = Keyword.get(opts, :field, :image_file_id)
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
      if is_integer(Map.get(changeset.context, context_key)) do
        :ok =
          changeset.context
          |> Map.fetch!(context_key)
          |> Files.delete_file_and_maybe_payload()
          |> normalize_delete_result()
      end

      {:ok, record}
    end)
  end

  defp normalize_delete_result(:ok), do: :ok
  defp normalize_delete_result({:error, _reason}), do: :ok
end
