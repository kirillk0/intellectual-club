defmodule IntellectualClubWeb.AshJsonApi.LlmConfigurationsTagBindingsManagementTest do
  @moduledoc """
  Regression tests for managing configuration tag bindings through the LLM configuration update action.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Knowledge.KnowledgeBlock

  alias IntellectualClub.Llm.{
    LlmConfiguration,
    LlmConfigurationKnowledgeBlock,
    LlmConfigurationTag,
    LlmConfigurationTagBinding,
    LlmProvider
  }

  require Ash.Query

  @configuration_include_query Enum.join(
                                 [
                                   "include=provider,knowledge_block_bindings.knowledge_block,tag_bindings.llm_configuration_tag"
                                 ],
                                 "&"
                               )

  defp json_api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end

  defp json_api_patch(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> patch(path, body)
  end

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  defp relationship_ids(%{"data" => %{"relationships" => relationships}}, rel_name) do
    case relationships |> Map.get(rel_name, %{}) |> Map.get("data") do
      data when is_list(data) ->
        data
        |> Enum.map(&Map.fetch!(&1, "id"))
        |> Enum.map(&String.to_integer/1)
        |> Enum.sort()

      %{"id" => id} ->
        [String.to_integer(id)]

      _other ->
        []
    end
  end

  defp relationship_ids(_resp, _rel_name), do: []

  defp ids_from_included(%{"included" => included}, type) when is_list(included) do
    included
    |> Enum.filter(&(&1["type"] == type))
    |> Enum.map(&Map.fetch!(&1, "id"))
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  defp ids_from_included(_resp, _type), do: []

  test "POST GET and PATCH /api/ash/llm-configurations handle fix_role_alteration", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Provider role fix",
          type: :demo,
          auth_method: :api_key,
          base_url: "http://localhost",
          api_key: "test"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)

    create_response =
      conn
      |> json_api_post("/api/ash/llm-configurations", %{
        "data" => %{
          "type" => "llm-configurations",
          "attributes" => %{
            "provider_id" => provider.id,
            "model_name" => "role-fix-model",
            "parameters" => %{},
            "enabled" => true,
            "timeout_seconds" => 300,
            "fix_role_alteration" => true
          }
        }
      })
      |> json_response(201)

    configuration_id = create_response["data"]["id"]

    assert get_in(create_response, ["data", "attributes", "fix_role_alteration"]) == true

    get_response =
      conn
      |> json_api_get("/api/ash/llm-configurations/#{configuration_id}")
      |> json_response(200)

    assert get_in(get_response, ["data", "attributes", "fix_role_alteration"]) == true

    patch_response =
      conn
      |> json_api_patch("/api/ash/llm-configurations/#{configuration_id}", %{
        "data" => %{
          "type" => "llm-configurations",
          "id" => configuration_id,
          "attributes" => %{"fix_role_alteration" => false}
        }
      })
      |> json_response(200)

    assert get_in(patch_response, ["data", "attributes", "fix_role_alteration"]) == false

    configuration = Ash.get!(LlmConfiguration, String.to_integer(configuration_id), actor: actor)
    assert configuration.fix_role_alteration == false
  end

  test "GET /api/ash/llm-configurations/:id includes provider, tags, and knowledge blocks", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Provider A",
          type: :demo,
          auth_method: :api_key,
          base_url: "http://localhost",
          api_key: "test"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tag =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag One"}, actor: actor)
      |> Ash.create!(actor: actor)

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block", version: "v1", content: "x", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "model-a",
          note: "cfg",
          parameters: %{},
          enabled: true,
          timeout_seconds: 300
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tag_binding =
      LlmConfigurationTagBinding
      |> Ash.Changeset.for_create(
        :create,
        %{llm_configuration_id: configuration.id, llm_configuration_tag_id: tag.id},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block_binding =
      LlmConfigurationKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: configuration.id,
          knowledge_block_id: block.id,
          enabled: true,
          selection: :bottom,
          sequence: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_get(
        "/api/ash/llm-configurations/#{configuration.id}?#{@configuration_include_query}"
      )
      |> json_response(200)

    assert relationship_ids(response, "provider") == [provider.id]
    assert relationship_ids(response, "tag_bindings") == [tag_binding.id]
    assert relationship_ids(response, "knowledge_block_bindings") == [block_binding.id]
    assert ids_from_included(response, "llm-providers") == [provider.id]
    assert ids_from_included(response, "llm-configuration-tags") == [tag.id]
    assert ids_from_included(response, "knowledge-blocks") == [block.id]
  end

  test "PATCH /api/ash/llm-configurations/:id manages tag bindings", %{conn: conn} do
    %{user: actor, password: password} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Provider A",
          type: :demo,
          auth_method: :api_key,
          base_url: "http://localhost",
          api_key: "test"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tag1 =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag One"}, actor: actor)
      |> Ash.create!(actor: actor)

    tag2 =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag Two"}, actor: actor)
      |> Ash.create!(actor: actor)

    block1 =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block One", version: "v1", content: "x", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block2 =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Block Two", version: "v2", content: "y", variables: %{}},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "model-a",
          note: "cfg",
          parameters: %{},
          enabled: true,
          timeout_seconds: 300
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)

    resp1 =
      conn
      |> json_api_patch(
        "/api/ash/llm-configurations/#{configuration.id}?#{@configuration_include_query}",
        %{
          "data" => %{
            "type" => "llm-configurations",
            "id" => "#{configuration.id}",
            "attributes" => %{
              "tag_bindings" => [
                %{"llm_configuration_tag_id" => tag1.id},
                %{"llm_configuration_tag_id" => tag2.id}
              ],
              "knowledge_block_bindings" => [
                %{
                  "knowledge_block_id" => block1.id,
                  "enabled" => true,
                  "selection" => "bottom",
                  "sequence" => 0
                },
                %{
                  "knowledge_block_id" => block2.id,
                  "enabled" => true,
                  "selection" => "top",
                  "sequence" => 1
                }
              ]
            }
          }
        }
      )
      |> json_response(200)

    bindings1 =
      LlmConfigurationTagBinding
      |> Ash.Query.filter(llm_configuration_id == ^configuration.id)
      |> Ash.read!(actor: actor)

    assert Enum.sort(Enum.map(bindings1, & &1.llm_configuration_tag_id)) ==
             Enum.sort([tag1.id, tag2.id])

    block_bindings1 =
      LlmConfigurationKnowledgeBlock
      |> Ash.Query.filter(llm_configuration_id == ^configuration.id)
      |> Ash.Query.sort(selection: :asc, sequence: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.sort(Enum.map(block_bindings1, & &1.knowledge_block_id)) ==
             Enum.sort([block1.id, block2.id])

    assert relationship_ids(resp1, "provider") == [provider.id]
    assert relationship_ids(resp1, "tag_bindings") == Enum.sort(Enum.map(bindings1, & &1.id))

    assert relationship_ids(resp1, "knowledge_block_bindings") ==
             Enum.sort(Enum.map(block_bindings1, & &1.id))

    assert ids_from_included(resp1, "llm-providers") == [provider.id]
    assert ids_from_included(resp1, "llm-configuration-tags") == Enum.sort([tag1.id, tag2.id])
    assert ids_from_included(resp1, "knowledge-blocks") == Enum.sort([block1.id, block2.id])

    binding1 = Enum.find(bindings1, &(&1.llm_configuration_tag_id == tag1.id))
    assert binding1

    block_binding1 = Enum.find(block_bindings1, &(&1.knowledge_block_id == block1.id))
    assert block_binding1

    resp2 =
      conn
      |> json_api_patch(
        "/api/ash/llm-configurations/#{configuration.id}?#{@configuration_include_query}",
        %{
          "data" => %{
            "type" => "llm-configurations",
            "id" => "#{configuration.id}",
            "attributes" => %{
              "tag_bindings" => [
                %{"id" => binding1.id, "llm_configuration_tag_id" => tag1.id}
              ],
              "knowledge_block_bindings" => [
                %{
                  "id" => block_binding1.id,
                  "knowledge_block_id" => block1.id,
                  "enabled" => true,
                  "selection" => "bottom",
                  "sequence" => 0
                }
              ]
            }
          }
        }
      )
      |> json_response(200)

    bindings2 =
      LlmConfigurationTagBinding
      |> Ash.Query.filter(llm_configuration_id == ^configuration.id)
      |> Ash.read!(actor: actor)

    assert Enum.map(bindings2, & &1.llm_configuration_tag_id) == [tag1.id]

    block_bindings2 =
      LlmConfigurationKnowledgeBlock
      |> Ash.Query.filter(llm_configuration_id == ^configuration.id)
      |> Ash.Query.sort(selection: :asc, sequence: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(block_bindings2, & &1.knowledge_block_id) == [block1.id]
    assert relationship_ids(resp2, "provider") == [provider.id]
    assert relationship_ids(resp2, "tag_bindings") == Enum.map(bindings2, & &1.id)

    assert relationship_ids(resp2, "knowledge_block_bindings") ==
             Enum.map(block_bindings2, & &1.id)

    assert ids_from_included(resp2, "llm-providers") == [provider.id]
    assert ids_from_included(resp2, "llm-configuration-tags") == [tag1.id]
    assert ids_from_included(resp2, "knowledge-blocks") == [block1.id]
  end
end
