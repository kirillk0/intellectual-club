defmodule IntellectualClubWeb.SpaHTML do
  @moduledoc """
  Templates for the SPA shell served by `SpaController`.
  """

  use IntellectualClubWeb, :html

  embed_templates "spa_html/*"
end
