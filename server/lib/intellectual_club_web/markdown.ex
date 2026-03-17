defmodule IntellectualClubWeb.Markdown do
  @moduledoc """
  Markdown rendering helpers for LiveView templates.
  """

  alias IntellectualClubWeb.Scrubbers.ChatMarkdown

  @doc """
  Converts Markdown input into a safe HTML fragment suitable for HEEx rendering.

  This escapes HTML in the Markdown source and then runs the generated HTML
  through a scrubber to ensure only a restricted set of tags/attributes remains.
  """
  def to_safe_html(nil), do: Phoenix.HTML.raw("")

  def to_safe_html(markdown) when is_binary(markdown) do
    markdown = String.trim_trailing(markdown)

    html =
      case Earmark.as_html(markdown, breaks: true, gfm: true, gfm_tables: true, escape: true) do
        {:ok, html, _messages} -> html
        {:error, html, _messages} -> html
      end

    html
    |> wrap_tables()
    |> HtmlSanitizeEx.Scrubber.scrub(ChatMarkdown)
    |> Phoenix.HTML.raw()
  end

  def to_safe_html(_value), do: Phoenix.HTML.raw("")

  defp wrap_tables(html) when is_binary(html) do
    cond do
      not String.contains?(html, "<table") ->
        html

      String.contains?(html, "table-scroll") ->
        html

      true ->
        html
        |> String.replace("<table", ~s(<div class="table-scroll"><table))
        |> String.replace("</table>", "</table></div>")
    end
  end
end
