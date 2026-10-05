defmodule IntellectualClubWeb.Bff.LlmProvidersControllerTest do
  @moduledoc """
  LLM provider BFF endpoints: provider type metadata and upstream model discovery.
  """

  use IntellectualClubWeb.ConnCase, async: true

  describe "GET /api/bff/llm-provider-types" do
    test "returns provider metadata", %{conn: conn} do
      %{user: actor, password: password} = user_fixture()

      response =
        conn
        |> sign_in_conn(actor.username, password)
        |> get("/api/bff/llm-provider-types")
        |> json_response(200)

      types = response["types"]
      anthropic = Enum.find(types, &(&1["type"] == "anthropic_messages"))
      nvidia = Enum.find(types, &(&1["type"] == "nvidia_build_chat_completion"))
      openrouter = Enum.find(types, &(&1["type"] == "openrouter_chat_completion"))
      responses = Enum.find(types, &(&1["type"] == "responses"))
      responses_wss = Enum.find(types, &(&1["type"] == "responses_wss"))
      google = Enum.find(types, &(&1["type"] == "google_interactions"))

      assert anthropic["default_auth_method"] == "api_key"

      assert anthropic["base_url_options"] == [
               "https://api.anthropic.com/v1",
               "https://api.deepseek.com/anthropic"
             ]

      assert anthropic["supports_model_discovery"] == true
      assert anthropic["supports_hosted_web_search"] == true

      assert openrouter["default_auth_method"] == "api_key"
      assert openrouter["base_url_options"] == ["https://openrouter.ai/api/v1"]
      assert openrouter["supports_model_discovery"] == true
      assert openrouter["supports_hosted_web_search"] == true

      assert nvidia["label"] == "NVIDIA Build Chat Completions"
      assert nvidia["default_auth_method"] == "api_key"
      assert nvidia["base_url_options"] == ["https://integrate.api.nvidia.com/v1"]
      assert nvidia["supports_model_discovery"] == true
      assert nvidia["supports_hosted_web_search"] == false

      assert Enum.any?(responses["auth_methods"], fn method ->
               method["value"] == "openai_oauth_refresh_token" and
                 method["credential"] == "oauth_refresh_token"
             end)

      assert responses_wss["label"] == "Responses API (WSS)"
      assert responses_wss["selectable"] == false
      assert responses_wss["default_auth_method"] == responses["default_auth_method"]
      assert responses_wss["auth_methods"] == responses["auth_methods"]
      assert responses_wss["base_url_options"] == responses["base_url_options"]
      assert responses_wss["default_base_url"] == responses["default_base_url"]
      assert responses_wss["supports_model_discovery"] == responses["supports_model_discovery"]
      assert responses["supports_hosted_web_search"] == true

      assert responses_wss["supports_hosted_web_search"] ==
               responses["supports_hosted_web_search"]

      assert responses["base_url_options"] == [
               "https://api.openai.com/v1",
               "wss://api.openai.com/v1",
               "https://chatgpt.com/backend-api/codex",
               "wss://chatgpt.com/backend-api/codex"
             ]

      assert google["label"] == "Google Interactions API"
      assert google["default_auth_method"] == "api_key"

      assert google["base_url_options"] == [
               "https://generativelanguage.googleapis.com/v1",
               "https://generativelanguage.googleapis.com/v1beta"
             ]

      assert google["supports_model_discovery"] == true
      assert google["supports_hosted_web_search"] == true

      demo = Enum.find(types, &(&1["type"] == "demo"))
      assert demo["supports_hosted_web_search"] == false
    end
  end

  @gpt_5_5 %{
    "id" => "gpt-5.5",
    "context_length" => 272_000,
    "architecture" => %{"input_modalities" => ["text", "image"]}
  }

  @gpt_5_5_model %{
    "id" => "gpt-5.5",
    "label" => "gpt-5.5",
    "context_length" => 272_000,
    "supports_image_input" => true
  }

  @bearer {"authorization", "Bearer test-key"}
  @anthropic_headers [{"x-api-key", "test-key"}, {"anthropic-version", "2023-06-01"}]

  # {name, provider type, base path, upstream {status, body}, expected models,
  #  expected query string, expected request headers}
  @discovery [
    {"loads the sparse NVIDIA catalog", :nvidia_build_chat_completion, "",
     {200,
      %{
        "object" => "list",
        "data" => [
          %{"id" => "nvidia/nemotron-3-nano-30b-a3b", "object" => "model", "owned_by" => "nvidia"}
        ]
      }},
     [
       %{
         "id" => "nvidia/nemotron-3-nano-30b-a3b",
         "label" => "nvidia/nemotron-3-nano-30b-a3b",
         "context_length" => nil,
         "supports_image_input" => nil
       }
     ], "", [@bearer]},
    {"loads OpenRouter tool-capable models", :openrouter_chat_completion, "",
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
      }},
     [
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
     ], "supported_parameters=tools", [@bearer]},
    {"loads Anthropic models", :anthropic_messages, "",
     {200,
      %{
        "data" => [
          %{
            "id" => "claude-sonnet-4-20250514",
            "display_name" => "Claude Sonnet 4",
            "type" => "model"
          }
        ],
        "first_id" => "claude-sonnet-4-20250514",
        "has_more" => false,
        "last_id" => "claude-sonnet-4-20250514"
      }},
     [
       %{
         "id" => "claude-sonnet-4-20250514",
         "label" => "Claude Sonnet 4",
         "context_length" => nil,
         "supports_image_input" => nil
       }
     ], "", @anthropic_headers},
    {"treats a missing Anthropic-compatible model list as empty", :anthropic_messages,
     "/anthropic", {404, ""}, [], "", @anthropic_headers},
    {"parses the Responses data schema", :responses, "", {200, %{"data" => [@gpt_5_5]}},
     [@gpt_5_5_model], "client_version=1.0.0", []},
    {"delegates responses_wss discovery to Responses", :responses_wss, "",
     {200, %{"data" => [@gpt_5_5]}}, [@gpt_5_5_model], "client_version=1.0.0", []},
    {"parses the Codex models schema", :responses, "",
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
      }},
     [
       %{
         "id" => "gpt-5.4",
         "label" => "gpt-5.4",
         "context_length" => 272_000,
         "supports_image_input" => true
       }
     ], "client_version=1.0.0", []},
    {"parses the Google models schema", :google_interactions, "",
     {200,
      %{
        "models" => [
          %{
            "name" => "models/gemini-2.5-flash-lite",
            "displayName" => "Gemini 2.5 Flash-Lite",
            "inputTokenLimit" => 1_048_576
          }
        ]
      }},
     [
       %{
         "id" => "gemini-2.5-flash-lite",
         "label" => "Gemini 2.5 Flash-Lite",
         "context_length" => 1_048_576,
         "supports_image_input" => true
       }
     ], "", [{"x-goog-api-key", "test-key"}]}
  ]

  describe "GET /api/bff/llm-providers/:id/models" do
    for {name, type, base_path, upstream, models, query, headers} <- @discovery do
      test name, %{conn: conn} do
        %{user: actor} = fixture = user_fixture()
        path = unquote(base_path) <> "/models"

        {base_url, agent} =
          start_scripted_server!(%{path => [unquote(Macro.escape(upstream))]},
            response: :json,
            record: :query
          )

        provider =
          create_provider!(actor,
            type: unquote(type),
            base_url: provider_base_url(unquote(type), base_url <> unquote(base_path))
          )

        assert conn |> sign_in_conn(fixture) |> get_models(provider) |> json_response(200) ==
                 %{"models" => unquote(Macro.escape(models))}

        assert [request] = scripted_requests(agent, path)
        assert request.query_string == unquote(query)
        for header <- unquote(Macro.escape(headers)), do: assert(header in request.headers)
      end
    end

    test "returns an empty list for demo providers", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()
      provider = create_provider!(actor, type: :demo)

      assert conn |> sign_in_conn(fixture) |> get_models(provider) |> json_response(200) ==
               %{"models" => []}
    end

    test "maps upstream failures to 502 without leaking the upstream error", %{conn: conn} do
      %{user: actor} = fixture = user_fixture()

      {base_url, _agent} =
        start_scripted_server!(
          %{"/models" => [{400, %{"error" => %{"message" => "secret-bearing upstream error"}}}]},
          response: :json
        )

      provider = create_provider!(actor, type: :responses, base_url: base_url)

      assert conn |> sign_in_conn(fixture) |> get_models(provider) |> json_response(502) ==
               %{"error" => "Provider model list request failed with HTTP 400."}
    end

    test "requires authentication", %{conn: conn} do
      %{user: owner} = user_fixture()
      provider = create_provider!(owner, type: :responses, base_url: "http://127.0.0.1:1")

      assert get_models(conn, provider).status == 401
    end
  end

  defp get_models(conn, provider), do: get(conn, "/api/bff/llm-providers/#{provider.id}/models")

  defp provider_base_url(:responses_wss, base_url),
    do: String.replace_prefix(base_url, "http://", "ws://")

  defp provider_base_url(_type, base_url), do: base_url
end
