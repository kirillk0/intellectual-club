defmodule IntellectualClub.Chat.LinkedForkCleanupLocksFixtureDomain do
  @moduledoc false

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(IntellectualClub.Chat.LinkedForkCleanupLocksUsageFixture)
    resource(IntellectualClub.Chat.LinkedForkCleanupLocksTaskFixture)
  end
end
