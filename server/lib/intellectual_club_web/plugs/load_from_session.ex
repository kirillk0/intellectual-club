defmodule IntellectualClubWeb.Plugs.LoadFromSession do
  @moduledoc """
  Loads the session user like `AshAuthentication.Phoenix.Plug.load_from_session/2`,
  without signing the user out when the database cannot be reached.

  AshAuthentication treats every failed token check as a definitive rejection:
  a revocation lookup that errors is assumed to mean "revoked", and any failure
  deletes the token from the session. Under database pool exhaustion this
  silently logs users out.

  When the session holds a token but no user could be loaded, this plug looks
  the token record up again through the token resource:

    * no live record - the rejection is final, the session stays cleared;
    * live record - the database is reachable again, the load is retried once;
    * lookup error - the outcome is unknown, so the original session is kept,
      `current_user` is `nil` and the request is answered with `503`
      (`on_unavailable: :halt`, the default) or flagged with the
      `:session_unavailable` assign (`on_unavailable: :continue`).
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias AshAuthentication.Jwt
  alias AshAuthentication.Plug.Helpers, as: AuthHelpers
  alias IntellectualClub.Accounts.User
  alias IntellectualClubWeb.Bff.Helpers

  @otp_app :intellectual_club
  @retries 1

  defmodule TokenLookup do
    @moduledoc """
    Looks up live session token records by `jti`.
    """

    @callback lookup(jti :: String.t()) :: {:ok, [struct()]} | {:error, term()}
  end

  defmodule AshTokenLookup do
    @moduledoc """
    Reads live user token records through the AshAuthentication token resource.
    """

    @behaviour IntellectualClubWeb.Plugs.LoadFromSession.TokenLookup

    alias AshAuthentication.TokenResource.Actions

    @impl true
    def lookup(jti) do
      {:ok, token_resource} =
        AshAuthentication.Info.authentication_tokens_token_resource(User)

      Actions.get_token(token_resource, %{"jti" => jti, "purpose" => "user"})
    end
  end

  @impl Plug
  def init(opts) do
    opts = Keyword.validate!(opts, on_unavailable: :halt)

    if opts[:on_unavailable] not in [:halt, :continue] do
      raise ArgumentError,
            "expected :on_unavailable to be :halt or :continue, got: " <>
              inspect(opts[:on_unavailable])
    end

    opts
  end

  @impl Plug
  def call(conn, opts) do
    conn = fetch_session(conn)
    load(conn, get_session(conn, session_key()), opts, @retries)
  end

  defp load(conn, token, opts, retries_left) do
    loaded = AuthHelpers.retrieve_from_session(conn, @otp_app)

    if is_binary(token) and is_nil(loaded.assigns[:current_user]) do
      case token_status(token) do
        :present when retries_left > 0 -> load(conn, token, opts, retries_left - 1)
        {:unavailable, reason} -> unavailable(conn, reason, opts)
        _final -> loaded
      end
    else
      loaded
    end
  end

  defp token_status(token) do
    with {:ok, %{"jti" => jti}} when is_binary(jti) <- Jwt.peek(token) do
      case lookup(jti) do
        {:ok, []} -> :missing
        {:ok, [_token | _rest]} -> :present
        {:error, reason} -> {:unavailable, reason}
      end
    else
      _invalid -> :missing
    end
  end

  defp lookup(jti) do
    token_lookup().lookup(jti)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp token_lookup do
    Application.get_env(@otp_app, :session_token_lookup, AshTokenLookup)
  end

  defp unavailable(conn, reason, opts) do
    Logger.warning(
      "Session user could not be verified, keeping the session: " <>
        inspect(reason, limit: 5, printable_limit: 300)
    )

    conn = assign(conn, :current_user, nil)

    case Keyword.fetch!(opts, :on_unavailable) do
      :continue ->
        assign(conn, :session_unavailable, true)

      :halt ->
        conn
        |> IntellectualClubWeb.Locale.call([])
        |> Helpers.render_unavailable()
        |> halt()
    end
  end

  defp session_key do
    "#{AshAuthentication.Info.authentication_subject_name!(User)}_token"
  end
end
