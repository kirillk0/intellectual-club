defmodule IntellectualClubWeb.AshJsonApi.LlmConfigurationsDeleteTest do
  @moduledoc """
  Regression tests for LLM configuration deletion through Ash JSON:API endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmConfigurationKnowledgeBlock
  alias IntellectualClub.Llm.LlmProvider

  require Ash.Query

  test "DELETE /api/ash/llm-configurations/:id removes dependent links and clears chat references",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Delete provider",
          type: :demo,
          auth_method: :api_key,
          base_url: "http://localhost",
          api_key: "test"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    configuration =
      LlmConfiguration
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider_id: provider.id,
          model_name: "delete-model",
          parameters: %{},
          enabled: true,
          timeout_seconds: 30,
          context_length: 1024,
          supports_cache_control: false,
          supports_image_input: false
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Delete config block", content: "x"},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _binding =
      LlmConfigurationKnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{
          llm_configuration_id: configuration.id,
          knowledge_block_id: block.id,
          enabled: true,
          sequence: 0
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Delete config chat",
          llm_configuration_id: configuration.id,
          note: "",
          variables: %{}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    message =
      ChatMessage
      |> Ash.Changeset.for_create(
        :add_message,
        %{
          chat_id: chat.id,
          role: :assistant,
          status: :done,
          llm_configuration_id: configuration.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    conn =
      conn
      |> sign_in_conn(actor.username, password)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> delete("/api/ash/llm-configurations/#{configuration.id}")

    assert conn.status in [200, 204], inspect(conn.resp_body)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(LlmConfiguration, configuration.id, actor: actor)

    remaining_bindings =
      LlmConfigurationKnowledgeBlock
      |> Ash.Query.filter(llm_configuration_id == ^configuration.id)
      |> Ash.read!(actor: actor)

    assert remaining_bindings == []

    updated_chat = Ash.get!(Chat, chat.id, actor: actor)
    assert updated_chat.llm_configuration_id == nil

    updated_message = Ash.get!(ChatMessage, message.id, actor: actor)
    assert updated_message.llm_configuration_id == nil
  end
end
