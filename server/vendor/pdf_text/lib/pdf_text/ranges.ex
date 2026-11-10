defmodule PdfText.Ranges do
  @moduledoc false
  alias PdfText.Context, as: C

  # Disjoint intervals admit logarithmic lookup without expanding their codes.
  # Overlapping definitions retain their input precedence and a charged linear
  # fallback. Both sorting and storage are bounded by cmap_entries.
  def new(ranges) do
    sorted = Enum.sort_by(ranges, &elem(&1, 0))

    {disjoint, _} =
      Enum.reduce(sorted, {true, -1}, fn {low, high, _}, {ok, prev} ->
        {ok and low > prev, max(high, prev)}
      end)

    if disjoint, do: {:sorted, List.to_tuple(sorted)}, else: {:linear, ranges}
  end

  def find({:sorted, tuple}, code), do: search(tuple, code, 0, tuple_size(tuple) - 1)

  def find({:linear, ranges}, code) do
    Enum.find_value(ranges, fn {low, high, value} ->
      C.tick(:cmap_work)
      if code >= low and code <= high, do: {low, value}
    end)
  end

  defp search(_, _, low, high) when high < low, do: nil

  defp search(tuple, code, low, high) do
    C.tick(:cmap_work)
    mid = div(low + high, 2)
    {first, last, value} = elem(tuple, mid)

    cond do
      code < first -> search(tuple, code, low, mid - 1)
      code > last -> search(tuple, code, mid + 1, high)
      true -> {first, value}
    end
  end
end
