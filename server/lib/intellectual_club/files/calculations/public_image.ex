defmodule IntellectualClub.Files.Calculations.PublicImage do
  @moduledoc """
  Exposes owner-scoped image metadata without exposing the internal file resource.
  """

  use Ash.Resource.Calculation

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File

  require Ash.Query

  @impl true
  def load(_query, _opts, _context), do: [:id, :image_file_id]

  @impl true
  def calculate(records, opts, _context) do
    route_prefix = Keyword.fetch!(opts, :route_prefix)

    files_by_id =
      records
      |> Enum.map(&Map.get(&1, :image_file_id))
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()
      |> load_files_by_id()

    Enum.map(records, fn record ->
      file = Map.get(files_by_id, Map.get(record, :image_file_id))
      Files.public_image(file, "#{route_prefix}/#{record.id}/image")
    end)
  end

  defp load_files_by_id([]), do: %{}

  defp load_files_by_id(file_ids) do
    File
    |> Ash.Query.filter(id in ^file_ids)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.id, &1})
  end
end
