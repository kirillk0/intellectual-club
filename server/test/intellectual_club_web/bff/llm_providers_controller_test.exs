defmodule IntellectualClubWeb.Bff.LlmProvidersControllerTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Llm.LlmProvider

  test "GET /api/bff/llm-provider-types returns provider metadata", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> get("/api/bff/llm-provider-types")
      |> json_response(200)

    types = response["types"]
    openrouter = Enum.find(types, &(&1["type"] == "openrouter_chat_completion"))
    responses = Enum.find(types, &(&1["type"] == "responses"))

    assert openrouter["default_auth_method"] == "api_key"
    assert openrouter["base_url_options"] == ["https://openrouter.ai/api/v1"]
    assert openrouter["supports_model_discovery"] == true

    assert Enum.any?(responses["auth_methods"], fn method ->
             method["value"] == "openai_oauth_refresh_token" and
               method["credential"] == "oauth_refresh_token"
           end)
  end

  test "GET /api/bff/llm-providers/:id/models loads OpenRouter tool-capable models", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    scripts = %{
      "/models" => [
        {200,
         %{
           "data" => [
             %{
               "id" => "openai/gpt-5-mini",
               "name" => "GPT 5 Mini",
               "context_length" => 128_000,
               "architecture" => %{"input_modalities" => ["text", "image"]}
             },
             %{
               "id" => "anthropic/claude-sonnet-4.5",
               "context_length" => 200_000,
               "architecture" => %{"input_modalities" => ["text"]}
             }
           ]
         }}
      ]
    }

    {base_url, agent} = start_scripted_server!(scripts)
    provider = create_provider!(actor, base_url, :openrouter_chat_completion)

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> get("/api/bff/llm-providers/#{provider.id}/models")
      |> json_response(200)

    assert response["models"] == [
             %{
               "id" => "openai/gpt-5-mini",
               "label" => "GPT 5 Mini",
               "context_length" => 128_000,
               "supports_image_input" => true
             },
             %{
               "id" => "anthropic/claude-sonnet-4.5",
               "label" => "anthropic/claude-sonnet-4.5",
               "context_length" => 200_000,
               "supports_image_input" => false
             }
           ]

    [request] = requests_for(agent, "/models")
    assert request.query_string == "supported_parameters=tools"
    assert {"authorization", "Bearer test-key"} in request.headers
  end

  test "GET /api/bff/llm-providers/:id/models parses responses data schema", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    scripts = %{
      "/models" => [
        {200,
         %{
           "data" => [
             %{
               "id" => "gpt-5.5",
               "context_length" => 272_000,
               "architecture" => %{"input_modalities" => ["text", "image"]}
             }
           ]
         }}
      ]
    }

    {base_url, agent} = start_scripted_server!(scripts)
    provider = create_provider!(actor, base_url, :responses)

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> get("/api/bff/llm-providers/#{provider.id}/models")
      |> json_response(200)

    assert response["models"] == [
             %{
               "id" => "gpt-5.5",
               "label" => "gpt-5.5",
               "context_length" => 272_000,
               "supports_image_input" => true
             }
           ]

    [request] = requests_for(agent, "/models")
    assert request.query_string == "client_version=1.0.0"
  end

  test "GET /api/bff/llm-providers/:id/models parses Codex models schema", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    scripts = %{
      "/models" => [
        {200,
         %{
           "models" => [
             %{
               "slug" => "gpt-5.4",
               "display_name" => "gpt-5.4",
               "context_window" => 272_000,
               "input_modalities" => ["text", "image"]
             }
           ]
         }}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)
    provider = create_provider!(actor, base_url, :responses)

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> get("/api/bff/llm-providers/#{provider.id}/models")
      |> json_response(200)

    assert response["models"] == [
             %{
               "id" => "gpt-5.4",
               "label" => "gpt-5.4",
               "context_length" => 272_000,
               "supports_image_input" => true
             }
           ]
  end

  test "GET /api/bff/llm-providers/:id/models returns an empty list for demo providers", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Demo provider", type: :demo, auth_method: :api_key},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> get("/api/bff/llm-providers/#{provider.id}/models")
      |> json_response(200)

    assert response == %{"models" => []}
  end

  test "GET /api/bff/llm-providers/:id/models maps upstream failures to 502", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    scripts = %{
      "/models" => [
        {400, %{"error" => %{"message" => "secret-bearing upstream error"}}}
      ]
    }

    {base_url, _agent} = start_scripted_server!(scripts)
    provider = create_provider!(actor, base_url, :responses)

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> get("/api/bff/llm-providers/#{provider.id}/models")
      |> json_response(502)

    assert response == %{"error" => "Provider model list request failed with HTTP 400."}
  end

  test "GET /api/bff/llm-providers/:id/models requires authentication", %{conn: conn} do
    %{user: owner} = user_fixture()
    provider = create_provider!(owner, "http://127.0.0.1:1", :responses)

    conn =
      conn
      |> get("/api/bff/llm-providers/#{provider.id}/models")

    assert conn.status == 401
  end

  defp create_provider!(actor, base_url, type) do
    LlmProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Provider #{System.unique_integer([:positive])}",
        type: type,
        auth_method: :api_key,
        base_url: base_url,
        api_key: "test-key"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp start_scripted_server!(scripts) when is_map(scripts) do
    {:ok, agent} =
      start_supervised(
        {Agent,
         fn ->
           %{
             scripts: scripts,
             requests: %{}
           }
         end}
      )

    port = free_port()

    {:ok, _server} =
      start_supervised(
        {Bandit, plug: {__MODULE__.ScriptedPlug, agent: agent}, scheme: :http, port: port}
      )

    {"http://127.0.0.1:#{port}", agent}
  end

  defp requests_for(agent, path) do
    Agent.get(agent, fn state -> Map.get(state.requests, path, []) end)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defmodule ScriptedPlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      agent = Keyword.fetch!(opts, :agent)

      {response_body, status_code} =
        Agent.get_and_update(agent, fn state ->
          request_path = conn.request_path

          request = %{
            query_string: conn.query_string,
            headers: conn.req_headers
          }

          requests =
            Map.update(state.requests, request_path, [request], fn existing ->
              existing ++ [request]
            end)

          case Map.get(state.scripts, request_path, []) do
            [{code, body} | rest] ->
              {{body, code},
               %{state | scripts: Map.put(state.scripts, request_path, rest), requests: requests}}

            [] ->
              {{%{"error" => "No scripted response for #{request_path}"}, 500},
               %{state | requests: requests}}
          end
        end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status_code, Jason.encode!(response_body))
    end
  end
end
