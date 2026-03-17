defmodule IntellectualClub.Files.Changes.ClearImageFile do
  @moduledoc """
  Clears an image file reference and deletes the logical file if needed.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Files

  @impl true
  def change(changeset, opts, _context) do
    field = Keyword.get(opts, :field, :image_file_id)
    old_context_key = {__MODULE__, field, :old_file_id}

    changeset
    |> Changeset.before_action(fn changeset ->
      old_file_id =
        Changeset.get_attribute(changeset, field) ||
          case changeset.data do
            %{^field => value} -> value
            _ -> nil
          end

      changeset
      |> Changeset.put_context(old_context_key, old_file_id)
      |> Changeset.force_change_attribute(field, nil)
    end)
    |> Changeset.after_action(fn changeset, record ->
      if is_integer(Map.get(changeset.context, old_context_key)) do
        :ok =
          changeset.context
          |> Map.fetch!(old_context_key)
          |> Files.delete_file_and_maybe_payload()
          |> normalize_delete_result()
      end

      {:ok, record}
    end)
  end

  defp normalize_delete_result(:ok), do: :ok
  defp normalize_delete_result({:error, _reason}), do: :ok
end
