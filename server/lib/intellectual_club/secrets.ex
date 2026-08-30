defmodule IntellectualClub.Secrets do
  @moduledoc """
  Encrypted secrets owned by individual knowledge-block or tool attachments.
  """

  use Ash.Domain

  alias IntellectualClub.Secrets.Secret

  resources do
    resource(Secret)
    resource(IntellectualClub.Secrets.KnowledgeBlockSecret)
    resource(IntellectualClub.Secrets.ToolInstanceSecret)
  end

  @spec duplicate_secret(pos_integer(), Ash.Resource.record() | map()) ::
          {:ok, Secret.t()} | {:error, term()}
  def duplicate_secret(secret_id, actor) when is_integer(secret_id) do
    with {:ok, %Secret{} = source} <- Ash.get(Secret, secret_id, actor: actor) do
      Secret
      |> Ash.Changeset.for_create(
        :create_encrypted,
        %{
          name: source.name,
          description: source.description,
          encrypted_value: source.encrypted_value
        },
        actor: actor
      )
      |> Ash.create(actor: actor)
    end
  end
end
