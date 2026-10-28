defmodule IntellectualClub.Chat.Types.MessagePage do
  @moduledoc "A bounded page of a chat's effective active branch, in conversation order."
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        chat_id: [type: :integer, allow_nil?: false],
        messages: [type: {:array, IntellectualClub.Chat.Types.MessageView}, allow_nil?: false],
        next_offset: [type: :integer],
        has_more: [type: :boolean, allow_nil?: false]
      ]
    ]
end
