defmodule IntellectualClub.Llm.Providers.Common.ImageTraversal do
  @moduledoc """
  Structural traversal for provider-owned image mappers.

  Providers supply root keys, a container-to-child-key callback, and a block
  mapper. This helper has no knowledge of provider names, images or wire shapes.
  Nested container children must be lists; arbitrary map values are never scanned.
  """

  @spec map(map(), term(), [String.t()], (map(), term() -> :skip | {map(), term()}), (map() ->
                                                                                        String.t()
                                                                                        | nil)) ::
          {map(), term()}
  def map(request, acc, roots, mapper, child_key) when is_map(request) do
    Enum.reduce(roots, {request, acc}, fn key, {request, acc} ->
      case Map.fetch(request, key) do
        {:ok, value} ->
          {value, acc} = walk_root(value, acc, mapper, child_key)
          {Map.put(request, key, value), acc}

        :error ->
          {request, acc}
      end
    end)
  end

  def map(request, acc, _roots, _mapper, _child_key), do: {request, acc}

  defp walk_root(items, acc, mapper, child_key) when is_list(items),
    do: Enum.map_reduce(items, acc, &walk_item(&1, &2, mapper, child_key))

  defp walk_root(item, acc, mapper, child_key), do: walk_item(item, acc, mapper, child_key)

  defp walk_item(%{} = item, acc, mapper, child_key) do
    case mapper.(item, acc) do
      :skip ->
        key = child_key.(item)

        case key && Map.get(item, key) do
          children when is_list(children) ->
            {children, acc} =
              Enum.map_reduce(children, acc, &walk_item(&1, &2, mapper, child_key))

            {Map.put(item, key, children), acc}

          _other ->
            {item, acc}
        end

      {mapped, acc} ->
        {mapped, acc}
    end
  end

  defp walk_item(other, acc, _mapper, _child_key), do: {other, acc}
end
