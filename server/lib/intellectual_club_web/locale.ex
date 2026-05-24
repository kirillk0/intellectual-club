defmodule IntellectualClubWeb.Locale do
  @moduledoc """
  Resolves and stores the effective UI locale for request-local translations.
  """

  import Plug.Conn

  @default_locale "en"
  @supported_locales ~w(en ru)

  def init(opts), do: opts

  def call(conn, _opts) do
    locale =
      conn
      |> locale_from_header()
      |> Kernel.||(locale_from_actor(conn))
      |> Kernel.||(locale_from_accept_language(conn))
      |> Kernel.||(@default_locale)

    Gettext.put_locale(IntellectualClubWeb.Gettext, locale)
    assign(conn, :ui_locale, locale)
  end

  def supported?(locale), do: locale in @supported_locales

  def normalize(locale) when is_binary(locale) do
    locale
    |> String.trim()
    |> String.downcase()
    |> String.split(["-", "_"], parts: 2)
    |> List.first()
    |> case do
      locale when locale in @supported_locales -> locale
      _other -> nil
    end
  end

  def normalize(_locale), do: nil

  defp locale_from_header(conn) do
    conn
    |> get_req_header("x-ui-locale")
    |> List.first()
    |> normalize()
  end

  defp locale_from_actor(conn) do
    case Ash.PlugHelpers.get_actor(conn) || conn.assigns[:current_user] do
      %{preferred_locale: locale} -> normalize(locale)
      _other -> nil
    end
  end

  defp locale_from_accept_language(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> parse_accept_language()
  end

  defp parse_accept_language(nil), do: nil

  defp parse_accept_language(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn entry ->
      entry
      |> String.split(";", parts: 2)
      |> List.first()
      |> normalize()
    end)
  end
end
