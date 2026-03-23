defmodule IntellectualClub.Chat.Validations.PreventDestroyWithChildren do
  @moduledoc """
  Prevents direct message deletion while child messages still exist.
  """

  use Ash.Resource.Validation

  alias IntellectualClub.Chat.ChatMessage

  require Ash.Query

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    message_id = changeset.data.id

    query =
      ChatMessage
      |> Ash.Query.filter(parent_id == ^message_id)

    case Ash.exists(query, query_opts(context)) do
      {:ok, true} -> {:error, message: "cannot delete a message that has child messages"}
      {:ok, false} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp query_opts(%{actor: actor}) when not is_nil(actor), do: [actor: actor]
  defp query_opts(_context), do: [authorize?: false]
end
