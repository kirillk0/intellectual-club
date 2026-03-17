defmodule IntellectualClubWeb.AshJsonApi.LlmConfigurationsDuplicationTest do
  @moduledoc """
  Regression tests for LLM configuration duplication through Ash JSON:API endpoints.
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

  defp json_api_post(conn, path, body) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> post(path, body)
  end

  test "POST /api/ash/llm-configurations/:id/duplicate copies knowledge block and tag bindings",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Duplicate provider",
          type: :demo,
          auth_method: :api_key,
          base_url: "http://localhost",
          api_key: "test"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block_a =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Config block A", version: "v1", type: :rules, content: "A"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block_b =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Config block B", version: "v1", type: :rules, content: "B"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tag_a =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag A"}, actor: actor)
      |> Ash.create!(actor: actor)

    tag_b =
      LlmConfigurationTag
      |> Ash.Changeset.for_create(:create, %{name: "Tag B"}, actor: actor)
      |> Ash.create!(actor: actor)

    source_configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "duplicate-model",
          note: "source note",
          parameters: %{"temperature" => 0.3},
          enabled: true,
          timeout_seconds: 45,
          context_length: 16_384,
          supports_cache_control: true,
          supports_image_input: false,
          tag_bindings: [
            %{llm_configuration_tag_id: tag_a.id},
            %{llm_configuration_tag_id: tag_b.id}
          ],
          knowledge_block_bindings: [
            %{knowledge_block_id: block_a.id, selection: :top, enabled: true, sequence: 0},
            %{knowledge_block_id: block_b.id, selection: :bottom, enabled: false, sequence: 1}
          ]
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> json_api_post("/api/ash/llm-configurations/#{source_configuration.id}/duplicate", %{
        "data" => %{
          "type" => "llm-configurations",
          "attributes" => %{}
        }
      })
      |> json_response(201)

    duplicated_configuration_id = String.to_integer(response["data"]["id"])

    duplicated_bindings =
      LlmConfigurationKnowledgeBlock
      |> Ash.Query.filter(llm_configuration_id == ^duplicated_configuration_id)
      |> Ash.Query.sort(sequence: :asc, id: :asc)
      |> Ash.read!(actor: actor)

    assert Enum.map(
             duplicated_bindings,
             &{&1.knowledge_block_id, &1.selection, &1.enabled, &1.sequence}
           ) == [
             {block_a.id, :top, true, 0},
             {block_b.id, :bottom, false, 1}
           ]

    duplicated_tag_ids =
      LlmConfigurationTagBinding
      |> Ash.Query.filter(llm_configuration_id == ^duplicated_configuration_id)
      |> Ash.Query.sort(llm_configuration_tag_id: :asc)
      |> Ash.read!(actor: actor)
      |> Enum.map(& &1.llm_configuration_tag_id)

    assert duplicated_tag_ids == Enum.sort([tag_a.id, tag_b.id])
  end
end
