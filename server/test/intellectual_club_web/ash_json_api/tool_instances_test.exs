defmodule IntellectualClubWeb.AshJsonApi.ToolInstancesTest do
  @moduledoc """
  Tool instances through the AshJsonApi endpoints: config and secret
  validation, credential status, rate limits, sharing, duplication and
  deletion.
  """

  use IntellectualClubWeb.ConnCase, async: true

  import IntellectualClubWeb.AshJsonApiContract

  alias IntellectualClub.Outlets.PairingRequest
  alias IntellectualClub.Secrets.DriverSecrets

  alias IntellectualClub.Tools.{
    BotToolBinding,
    BotUserToolBinding,
    ChatToolBinding,
    ToolFunction,
    ToolInstance
  }

  require Ash.Query

  @collection "/api/ash/tool-instances"
  @type_name "tool-instances"

  describe "POST /api/ash/tool-instances" do
    for {name, attrs, expected_details} <- [
          {"SSH host and username",
           %{
             "type" => "ssh",
             "config" => %{"host" => "", "username" => ""},
             "secrets" => %{"password" => "secret"}
           }, ["Host is required.", "Username is required."]},
          {"MCP HTTP server URL",
           %{"type" => "mcp-http", "config" => %{"server_url" => ""}, "secrets" => %{}},
           ["Server URL is required."]},
          {"a stored value for a secret header",
           %{
             "type" => "mcp-http",
             "config" => %{
               "server_url" => "https://mcp.example.com",
               "open_headers" => %{},
               "secret_header_names" => ["X-Missing"]
             },
             "secrets" => %{"secret_headers" => %{}}
           }, ["missing a stored value for X-Missing"]}
        ] do
      test "rejects a config without #{name}" do
        details =
          user_fixture()
          |> api_create(
            @collection,
            @type_name,
            Map.merge(
              %{"name" => "Tool", "max_output_tokens" => 20_000},
              unquote(Macro.escape(attrs))
            )
          )
          |> assert_invalid!()

        for expected <- unquote(expected_details) do
          assert Enum.any?(details, &String.contains?(&1, expected)), inspect(details)
        end
      end
    end

    test "stores MCP config as given and moves secrets to driver storage" do
      %{user: actor} = owner = user_fixture()

      config = %{
        "server_url" => "https://mcp.example.com",
        "open_headers" => %{"X-Tenant-ID" => "tenant-42"},
        "secret_header_names" => ["X-API-Key"]
      }

      tool_id =
        owner
        |> api_create(@collection, @type_name, %{
          "type" => "mcp-http",
          "name" => "MCP",
          "config" => config,
          "secrets" => %{
            "token" => "mcp-token",
            "secret_headers" => %{"X-API-Key" => "secret-value"}
          },
          "max_output_tokens" => 20_000
        })
        |> json_response(201)
        |> response_id()

      tool = Ash.get!(ToolInstance, tool_id, actor: actor)
      assert tool.config == config
      assert tool.secrets == %{}

      assert DriverSecrets.values(tool) ==
               {:ok,
                %{
                  "bearer_token" => "mcp-token",
                  "secret_headers" => %{"X-API-Key" => "secret-value"}
                }}
    end
  end

  describe "PATCH /api/ash/tool-instances/:id" do
    test "merges nested secret header changes" do
      %{user: actor} = owner = user_fixture()

      tool =
        create_tool_instance!(actor,
          config: %{
            "server_url" => "https://mcp.example.com",
            "open_headers" => %{},
            "secret_header_names" => ["X-Keep", "X-Remove"]
          },
          secrets: %{
            "secret_headers" => %{"X-Keep" => "keep-value", "X-Remove" => "remove-value"}
          }
        )

      owner
      |> api_patch("#{@collection}/#{tool.id}", @type_name, tool.id, %{
        "config" => %{
          "server_url" => "https://mcp.example.com",
          "open_headers" => %{},
          "secret_header_names" => ["X-Keep", "X-New"]
        },
        "secrets" => %{"secret_headers" => %{"X-Remove" => "", "X-New" => "new-value"}}
      })
      |> json_response(200)

      updated = Ash.get!(ToolInstance, tool.id, actor: actor)
      assert updated.secrets == %{}

      assert DriverSecrets.values(updated) ==
               {:ok, %{"secret_headers" => %{"X-Keep" => "keep-value", "X-New" => "new-value"}}}
    end

    test "creates, updates and reads multiline descriptions" do
      owner = user_fixture()
      description = "Staging SSH\nUse for staging checks.\nLiteral {{tool_target}}."

      created =
        owner
        |> api_create(@collection, @type_name, %{
          "type" => "mcp-http",
          "name" => "Described tool",
          "alias" => "described_tool",
          "description" => description,
          "config" => %{"server_url" => "https://example.com/mcp"}
        })
        |> json_response(201)

      tool_id = response_id(created)
      assert created["data"]["attributes"]["description"] == description

      updated_description = "Production SSH\nUse only when the user explicitly says production."

      updated =
        owner
        |> api_patch("#{@collection}/#{tool_id}", @type_name, tool_id, %{
          "description" => updated_description
        })
        |> json_response(200)

      assert updated["data"]["attributes"]["description"] == updated_description

      assert api_attributes!(
               owner,
               "#{@collection}/#{tool_id}?fields[tool-instances]=description"
             ) ==
               %{"description" => updated_description}
    end

    test "accepts positive and null rps_limit values and rejects zero and negative ones" do
      %{user: actor} = owner = user_fixture()

      tool_id =
        owner
        |> api_create(@collection, @type_name, %{
          "type" => "mcp-http",
          "name" => "Limited tool",
          "config" => %{"server_url" => "https://example.com/mcp"},
          "rps_limit" => 0.5
        })
        |> json_response(201)
        |> tap(&assert(&1["data"]["attributes"]["rps_limit"] == 0.5))
        |> response_id()

      assert Ash.get!(ToolInstance, tool_id, actor: actor).rps_limit == 0.5

      for value <- [nil, 1.25] do
        response =
          owner
          |> api_patch("#{@collection}/#{tool_id}", @type_name, tool_id, %{"rps_limit" => value})
          |> json_response(200)

        assert response["data"]["attributes"]["rps_limit"] == value
        assert Ash.get!(ToolInstance, tool_id, actor: actor).rps_limit == value
      end

      for value <- [0, -0.5] do
        owner
        |> api_patch("#{@collection}/#{tool_id}", @type_name, tool_id, %{"rps_limit" => value})
        |> assert_invalid!()
      end

      assert Ash.get!(ToolInstance, tool_id, actor: actor).rps_limit == 1.25
    end
  end

  describe "GET /api/ash/tool-instances/:id" do
    for {name, attrs, present} <- [
          {"MCP bearer token and secret headers",
           %{
             type: "mcp-http",
             config: %{
               "server_url" => "https://example.com",
               "secret_header_names" => ["X-API-Key"]
             },
             secrets: %{
               "bearer_token" => "super-secret",
               "secret_headers" => %{"X-API-Key" => "header-secret"}
             }
           }, ["bearer_token", "secret_headers"]},
          {"MCP without secrets", %{type: "mcp-http", secrets: %{}}, []},
          {"SSH password",
           %{
             type: "ssh",
             config: %{"host" => "example.com", "username" => "root"},
             secrets: %{"password" => "super-secret"}
           }, ["password"]},
          {"SSH private key",
           %{
             type: "ssh",
             config: %{"host" => "example.net", "username" => "ubuntu"},
             secrets: %{"private_key" => "-----BEGIN OPENSSH PRIVATE KEY-----\n..."}
           }, ["private_key"]}
        ] do
      test "reports secrets_present without secrets for #{name}" do
        %{user: actor} = owner = user_fixture()
        tool = create_tool_instance!(actor, unquote(Macro.escape(attrs)))

        attributes = api_attributes!(owner, "#{@collection}/#{tool.id}")

        assert Enum.sort(attributes["secrets_present"]) == unquote(present)
        refute Map.has_key?(attributes, "secrets")
      end
    end

    test "includes stored functions" do
      %{user: actor} = owner = user_fixture()
      tool = create_tool_instance!(actor)

      functions =
        for name <- ["search", "lookup"], do: create_tool_function!(actor, tool, name: name)

      response = api_get!(owner, "#{@collection}/#{tool.id}?include=functions")

      function_ids = functions |> Enum.map(& &1.id) |> Enum.sort()
      assert relationship_ids(response, "functions") == function_ids
      assert ids_from_included(response, "tool-functions") == function_ids
    end
  end

  describe "tools shared through a bot" do
    setup do
      %{user: owner} = owner_fixture = user_fixture()
      %{user: recipient} = recipient_fixture = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})

      tool =
        create_tool_instance!(owner,
          description: "Shared tool\nModel-visible description.",
          secrets: %{"bearer_token" => "super-secret"},
          max_output_tokens: 1000,
          rps_limit: 0.5
        )

      function = create_tool_function!(owner, tool, name: "search", description: "Search")
      bot = create_bot!(owner)
      create_bot_tool_binding!(owner, bot, tool, alias: "shared_tool")
      share_bot!(owner, bot, group)

      %{owner: owner_fixture, recipient: recipient_fixture, tool: tool, function: function}
    end

    test "are readable but not updatable by recipients", %{recipient: recipient, tool: tool} do
      assert api_attributes!(
               recipient,
               "#{@collection}/#{tool.id}?fields[tool-instances]=description,rps_limit"
             ) == %{"description" => tool.description, "rps_limit" => 0.5}

      conn =
        api_patch(recipient, "#{@collection}/#{tool.id}", @type_name, tool.id, %{
          "rps_limit" => 2.0
        })

      assert conn.status in [403, 404]
    end

    for {copier, keeps_secrets?} <- [owner: true, recipient: false] do
      test "POST /:id/duplicate #{if keeps_secrets?, do: "preserves", else: "clears"} secrets for #{copier} copies",
           %{tool: source, function: function} = context do
        %{user: copier} = copier_fixture = context[unquote(copier)]

        {copy_id, _response} = duplicate!(copier_fixture, @collection, @type_name, source.id)

        copy = Ash.get!(ToolInstance, copy_id, actor: copier)
        assert copy.owner_id == copier.id
        assert copy.config == source.config
        assert copy.description == source.description
        assert copy.max_output_tokens == source.max_output_tokens
        assert copy.rps_limit == source.rps_limit

        if unquote(keeps_secrets?) do
          assert DriverSecrets.values(copy) == {:ok, source.secrets}
        else
          assert copy.secrets == %{}
          assert DriverSecrets.values(copy) == {:ok, %{}}
        end

        assert ToolFunction
               |> Ash.Query.filter(tool_instance_id == ^copy_id)
               |> Ash.read!(actor: copier)
               |> Enum.map(& &1.name) == [function.name]
      end
    end
  end

  describe "DELETE /api/ash/tool-instances/:id" do
    test "removes the tool with dependent rows and clears pairing references" do
      %{user: actor} = owner = user_fixture()
      bot = create_bot!(actor)
      tool = create_tool_instance!(actor)
      create_tool_function!(actor, tool, name: "search")
      create_bot_tool_binding!(actor, bot, tool, alias: "web")

      create!(
        BotUserToolBinding,
        %{
          bot_id: bot.id,
          tool_instance_id: tool.id,
          alias: "user_web",
          enabled: true,
          sequence: 0
        },
        actor
      )

      create_chat_tool_binding!(actor, create_chat!(actor), tool, alias: "chat_web")
      pairing = create_pairing_request!(tool)

      delete!(owner, "#{@collection}/#{tool.id}")

      assert_not_found(ToolInstance, tool.id, actor: actor)

      for resource <- [ToolFunction, BotToolBinding, BotUserToolBinding, ChatToolBinding] do
        refute resource |> Ash.read!(actor: actor) |> Enum.any?(&(&1.tool_instance_id == tool.id))
      end

      assert Ash.get!(PairingRequest, pairing.id, authorize?: false).tool_instance_id == nil
    end
  end

  defp create_pairing_request!(tool) do
    PairingRequest
    |> Ash.Changeset.for_create(
      :start,
      %{
        user_code: "ABCD-EFGH",
        device_code_hash: "hash",
        runner_kind: "outlet",
        requested_name: "Runner",
        created_user_agent: "test",
        metadata: %{},
        status: "approved",
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      },
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:update, %{tool_instance_id: tool.id}, authorize?: false)
    |> Ash.update!()
  end
end
