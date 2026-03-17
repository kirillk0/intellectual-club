defmodule IntellectualClubWeb.AshJsonApiRouter do
  @moduledoc """
  AshJsonApi router for generic resource access.

  Mounted under `/api/ash`.
  """

  use AshJsonApi.Router,
    domains: [
      IntellectualClub.Accounts,
      IntellectualClub.Bots,
      IntellectualClub.Chat,
      IntellectualClub.Knowledge,
      IntellectualClub.Llm,
      IntellectualClub.Tools
    ],
    open_api: "/open_api"
end
