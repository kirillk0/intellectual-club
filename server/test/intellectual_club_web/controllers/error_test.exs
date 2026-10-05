defmodule IntellectualClubWeb.ErrorTest do
  @moduledoc """
  Error pages rendered by `IntellectualClubWeb.ErrorHTML` and `IntellectualClubWeb.ErrorJSON`.
  """

  use ExUnit.Case, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  for {status, message} <- [{"404", "Not Found"}, {"500", "Internal Server Error"}] do
    test "renders #{status} as HTML and JSON" do
      assert render_to_string(IntellectualClubWeb.ErrorHTML, unquote(status), "html", []) ==
               unquote(message)

      assert IntellectualClubWeb.ErrorJSON.render(unquote(status) <> ".json", %{}) ==
               %{errors: %{detail: unquote(message)}}
    end
  end
end
