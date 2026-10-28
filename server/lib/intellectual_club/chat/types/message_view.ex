defmodule IntellectualClub.Chat.Types.MessageView do
  @moduledoc "Flat, read-only view of a message in an authorized conversation."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        id: [type: :integer, allow_nil?: false],
        chat_id: [type: :integer, allow_nil?: false],
        role: [type: :atom, constraints: [one_of: [:user, :assistant]], allow_nil?: false],
        status: [
          type: :atom,
          constraints: [one_of: [:generating, :done, :canceled, :error]],
          allow_nil?: false
        ],
        text: [type: :string, allow_nil?: false, constraints: [allow_empty?: true, trim?: false]],
        created_at: [type: :string, allow_nil?: false],
        finished_at: [type: :string],
        inherited: [type: :boolean, allow_nil?: false]
      ]
    ]
end
