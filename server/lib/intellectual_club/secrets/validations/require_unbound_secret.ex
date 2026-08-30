defmodule IntellectualClub.Secrets.Validations.RequireUnboundSecret do
  @moduledoc """
  Ensures a managed secret is owned by exactly one resource attachment.
  """

  use Ash.Resource.Validation

  alias IntellectualClub.Secrets.{KnowledgeBlockSecret, ToolInstanceSecret}

  require Ash.Query

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :secret_id) do
      secret_id when is_integer(secret_id) ->
        if bound?(KnowledgeBlockSecret, secret_id) or bound?(ToolInstanceSecret, secret_id) do
          {:error, field: :secret_id, message: "is already attached to another resource"}
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  defp bound?(resource, secret_id) do
    resource
    |> Ash.Query.filter(secret_id == ^secret_id)
    |> Ash.exists?(authorize?: false)
    |> case do
      true -> true
      false -> false
      {:ok, exists?} -> exists?
      _other -> true
    end
  end
end
