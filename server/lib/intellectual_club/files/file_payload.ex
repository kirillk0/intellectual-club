defmodule IntellectualClub.Files.FilePayload do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:sha256, :string, autogenerate: false}
  schema "file_payloads" do
    field :payload, :binary
  end
end
