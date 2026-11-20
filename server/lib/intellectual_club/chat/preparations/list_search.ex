defmodule IntellectualClub.Chat.Preparations.ListSearch do
  @moduledoc "Owner-only message-vector search, either indexed or within a bounded recent ID window."
  use Ash.Resource.Preparation
  alias IntellectualClub.Chat.MessageText
  require Ash.Query

  @impl true
  def prepare(query, _opts, %{actor: %{id: owner_id}})
      when is_integer(owner_id) and owner_id > 0 do
    search =
      MessageText.search(
        Ash.Query.get_argument(query, :q),
        Ash.Query.get_argument(query, :exact) == true
      )

    recent? = Ash.Query.get_argument(query, :strategy) == :recent

    query
    |> Ash.Query.filter(role in [:user, :assistant])
    |> MessageText.filter(search, owner_id: owner_id, recent?: recent?)
  end

  def prepare(query, _opts, _context), do: Ash.Query.filter(query, false)
end
