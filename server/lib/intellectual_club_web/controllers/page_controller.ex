defmodule IntellectualClubWeb.PageController do
  use IntellectualClubWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
