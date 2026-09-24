defmodule IntellectualClub.Chat.ForkHistoryFixtureDomain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(IntellectualClub.Chat.ForkHistoryCorruptFixture)
  end
end
