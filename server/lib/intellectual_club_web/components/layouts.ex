defmodule IntellectualClubWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use IntellectualClubWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :wide, :boolean,
    default: false,
    doc: "when true, content uses full page width instead of max container width"

  slot :header, doc: "optional content rendered in the sticky top bar"
  slot :header_actions, doc: "optional actions rendered on the right side of the top bar"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-[100dvh] flex-col bg-zinc-50 text-zinc-900">
      <header class="sticky top-0 z-30 border-b border-zinc-200/80 bg-zinc-50/80 backdrop-blur">
        <div class={[
          "flex flex-wrap items-center gap-3 px-4 py-2 sm:px-6",
          if(@wide, do: "w-full max-w-none", else: "w-full max-w-5xl mx-auto")
        ]}>
          <details class="relative">
            <summary
              class="flex cursor-pointer list-none items-center justify-center rounded-md p-2 text-sm font-medium text-zinc-700 transition hover:bg-zinc-200/60 hover:text-zinc-900 [&::-webkit-details-marker]:hidden"
              aria-label="Toggle navigation menu"
            >
              <.icon name="hero-bars-3" class="size-5" />
            </summary>

            <nav class="absolute left-0 top-[calc(100%+0.5rem)] z-40 w-60 overflow-hidden rounded-xl border border-zinc-200 bg-white shadow-lg">
              <div class="p-2">
                <.link
                  navigate={~p"/"}
                  class="block rounded-md px-3 py-2 text-sm font-medium text-zinc-700 transition hover:bg-zinc-100 hover:text-zinc-900"
                >
                  Chats
                </.link>
                <.link
                  navigate={~p"/catalogs"}
                  class="block rounded-md px-3 py-2 text-sm font-medium text-zinc-700 transition hover:bg-zinc-100 hover:text-zinc-900"
                >
                  Catalogs
                </.link>
                <.link
                  :if={@current_scope && @current_scope.user && @current_scope.user.is_admin}
                  href={~p"/admin"}
                  class="block rounded-md px-3 py-2 text-sm font-medium text-zinc-700 transition hover:bg-zinc-100 hover:text-zinc-900"
                >
                  Admin
                </.link>
              </div>

              <div class="border-t border-zinc-200 p-2">
                <div
                  :if={@current_scope && @current_scope.user}
                  class="px-3 py-2 text-sm font-medium text-zinc-700"
                >
                  {@current_scope.user.username}
                </div>
                <.link
                  :if={@current_scope && @current_scope.user}
                  href={~p"/sign-out"}
                  class="block rounded-md px-3 py-2 text-sm font-medium text-zinc-700 transition hover:bg-zinc-100 hover:text-zinc-900"
                >
                  Sign out
                </.link>
                <.link
                  :if={is_nil(@current_scope) || is_nil(@current_scope.user)}
                  navigate={~p"/login"}
                  class="block rounded-md px-3 py-2 text-sm font-medium text-zinc-700 transition hover:bg-zinc-100 hover:text-zinc-900"
                >
                  Sign in
                </.link>
              </div>
            </nav>
          </details>

          <div :if={@header != []} class="min-w-0 flex-1">
            {render_slot(@header)}
          </div>

          <div
            :if={@header_actions != []}
            class={[
              "min-w-0 flex items-center gap-2",
              if(@header == [], do: "flex-1", else: "flex-none")
            ]}
          >
            {render_slot(@header_actions)}
          </div>
        </div>
      </header>

      <main class={[
        "min-h-0 flex-1 px-4 py-4 sm:px-6",
        if(@wide, do: "w-full max-w-none", else: "w-full max-w-5xl mx-auto")
      ]}>
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:info}
        title={gettext("Reconnecting...")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  def tracked_asset_path(path) when is_binary(path) do
    if code_reloader?() do
      case dev_asset_version(path) do
        nil -> path
        version -> "#{path}?v=#{version}"
      end
    else
      path
    end
  end

  defp code_reloader? do
    :intellectual_club
    |> Application.get_env(IntellectualClubWeb.Endpoint, [])
    |> Keyword.get(:code_reloader, false)
  end

  defp dev_asset_version(path) do
    static_path =
      path
      |> String.trim_leading("/")
      |> then(&Path.join(Application.app_dir(:intellectual_club, "priv/static"), &1))

    case File.stat(static_path, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) -> mtime
      _ -> nil
    end
  end
end
