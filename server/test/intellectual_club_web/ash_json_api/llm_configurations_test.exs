defmodule IntellectualClubWeb.AshJsonApi.LlmConfigurationsTest do
  @moduledoc """
  LLM configurations and configuration tags through the AshJsonApi endpoints.
  """

  use IntellectualClubWeb.ConnCase, async: true

  import IntellectualClubWeb.AshJsonApiContract

  alias IntellectualClub.Bots.BotCompatibleConfigurationTag
  alias IntellectualClub.Chat.{Chat, ChatMessage}

  alias IntellectualClub.Llm.{
    LlmConfiguration,
    LlmConfigurationKnowledgeBlock,
    LlmConfigurationTagBinding
  }

  require Ash.Query

  @include "provider,knowledge_block_bindings.knowledge_block,tag_bindings.llm_configuration_tag"

  @prices [
    :cold_input_price_per_million_tokens,
    :cached_input_price_per_million_tokens,
    :output_price_per_million_tokens
  ]

  describe "mutable settings" do
    test "POST, GET and PATCH round-trip settings and accept null resets" do
      %{user: actor} = owner = user_fixture()
      provider = create_provider!(actor)

      created = %{
        fix_role_alteration: true,
        temperature: 0.7,
        reasoning_effort: :minimal,
        web_search_enabled: true,
        cold_input_price_per_million_tokens: 1.25,
        cached_input_price_per_million_tokens: 0.25,
        output_price_per_million_tokens: 5.0
      }

      create_response =
        owner
        |> api_create(
          "/api/ash/llm-configurations",
          "llm-configurations",
          Map.merge(json_attributes(created), %{
            "provider_id" => provider.id,
            "model_name" => "role-fix-model",
            "parameters" => %{},
            "enabled" => true,
            "timeout_seconds" => 300
          })
        )
        |> json_response(201)

      id = response_id(create_response)
      path = "/api/ash/llm-configurations/#{id}"
      assert_settings(create_response, created)
      assert_settings(api_get!(owner, path), created)

      updated = %{
        fix_role_alteration: false,
        temperature: 0.0,
        reasoning_effort: :max,
        web_search_enabled: false,
        cold_input_price_per_million_tokens: 2.0,
        cached_input_price_per_million_tokens: 0.5,
        output_price_per_million_tokens: 8.0
      }

      patch_response =
        owner
        |> api_patch(path, "llm-configurations", id, %{
          json_attributes(updated)
          | "temperature" => 0
        })
        |> json_response(200)

      assert_settings(patch_response, updated)
      assert_stored_settings(id, actor, updated)

      reset = Map.new([:temperature, :reasoning_effort | @prices], &{&1, nil})

      reset_response =
        owner
        |> api_patch(path, "llm-configurations", id, json_attributes(reset))
        |> json_response(200)

      assert_settings(reset_response, reset)
      assert_stored_settings(id, actor, Map.merge(updated, reset))
    end
  end

  describe "PATCH /api/ash/llm-configurations/:id" do
    test "manages tag and knowledge block bindings and keeps the provider" do
      %{user: actor} = owner = user_fixture()
      provider = create_provider!(actor)
      configuration = create_configuration!(actor, provider: provider, timeout_seconds: 300)
      tags = for _ <- 1..2, do: create_configuration_tag!(actor).id
      blocks = for _ <- 1..2, do: create_knowledge_block!(actor).id
      selections = [:bottom, :top]

      assert_manages_bindings(owner, %{
        collection: "/api/ash/llm-configurations",
        type: "llm-configurations",
        id: configuration.id,
        include: @include,
        static: [{"provider", "llm-providers", provider.id}],
        relationships: [
          %{
            name: "tag_bindings",
            resource: LlmConfigurationTagBinding,
            parent_key: :llm_configuration_id,
            target_key: :llm_configuration_tag_id,
            included: "llm-configuration-tags",
            targets: tags,
            attrs: fn tag_id, _index -> %{"llm_configuration_tag_id" => tag_id} end
          },
          %{
            name: "knowledge_block_bindings",
            resource: LlmConfigurationKnowledgeBlock,
            parent_key: :llm_configuration_id,
            target_key: :knowledge_block_id,
            included: "knowledge-blocks",
            targets: blocks,
            attrs: fn block_id, index ->
              %{
                "knowledge_block_id" => block_id,
                "enabled" => true,
                "selection" => Atom.to_string(Enum.at(selections, index)),
                "sequence" => index
              }
            end,
            project: &{&1.knowledge_block_id, &1.selection, &1.sequence},
            expect_set: Enum.zip([blocks, selections, [0, 1]]),
            expect_keep: [{hd(blocks), :bottom, 0}]
          }
        ]
      })
    end
  end

  describe "POST /api/ash/llm-configurations/:id/duplicate" do
    test "copies settings, knowledge block bindings and tag bindings" do
      %{user: actor} = owner = user_fixture()
      [block_a, block_b] = for _ <- 1..2, do: create_knowledge_block!(actor)
      [tag_a, tag_b] = for _ <- 1..2, do: create_configuration_tag!(actor)

      settings = %{
        fix_role_alteration: true,
        temperature: 0.7,
        reasoning_effort: :minimal,
        web_search_enabled: true,
        cold_input_price_per_million_tokens: 1.25,
        cached_input_price_per_million_tokens: 0.25,
        output_price_per_million_tokens: 5.0
      }

      source =
        create_configuration!(
          actor,
          Map.merge(settings, %{
            parameters: %{"temperature" => 0.3},
            timeout_seconds: 45,
            context_length: 16_384,
            supports_cache_control: true,
            tag_bindings: [
              %{llm_configuration_tag_id: tag_a.id},
              %{llm_configuration_tag_id: tag_b.id}
            ],
            knowledge_block_bindings: [
              %{knowledge_block_id: block_a.id, selection: :top, enabled: true, sequence: 0},
              %{knowledge_block_id: block_b.id, selection: :bottom, enabled: false, sequence: 1}
            ]
          })
        )

      {copy_id, _response} =
        duplicate!(owner, "/api/ash/llm-configurations", "llm-configurations", source.id)

      assert_stored_settings(copy_id, actor, settings)

      assert LlmConfigurationKnowledgeBlock
             |> Ash.Query.filter(llm_configuration_id == ^copy_id)
             |> Ash.Query.sort(sequence: :asc, id: :asc)
             |> Ash.read!(actor: actor)
             |> Enum.map(&{&1.knowledge_block_id, &1.selection, &1.enabled, &1.sequence}) == [
               {block_a.id, :top, true, 0},
               {block_b.id, :bottom, false, 1}
             ]

      assert LlmConfigurationTagBinding
             |> Ash.Query.filter(llm_configuration_id == ^copy_id)
             |> Ash.read!(actor: actor)
             |> Enum.map(& &1.llm_configuration_tag_id)
             |> Enum.sort() == Enum.sort([tag_a.id, tag_b.id])
    end
  end

  describe "DELETE /api/ash/llm-configurations/:id" do
    test "removes dependent bindings and clears chat and message references" do
      %{user: actor} = owner = user_fixture()
      configuration = create_configuration!(actor)

      create!(
        LlmConfigurationKnowledgeBlock,
        %{
          llm_configuration_id: configuration.id,
          knowledge_block_id: create_knowledge_block!(actor).id,
          enabled: true,
          sequence: 0
        },
        actor
      )

      chat = create_chat!(actor, llm_configuration_id: configuration.id)
      message = create_message!(actor, chat, llm_configuration_id: configuration.id)

      delete!(owner, "/api/ash/llm-configurations/#{configuration.id}")

      assert_not_found(LlmConfiguration, configuration.id, actor: actor)

      assert LlmConfigurationKnowledgeBlock
             |> Ash.Query.filter(llm_configuration_id == ^configuration.id)
             |> Ash.read!(actor: actor) == []

      assert Ash.get!(Chat, chat.id, actor: actor).llm_configuration_id == nil
      assert Ash.get!(ChatMessage, message.id, actor: actor).llm_configuration_id == nil
    end
  end

  describe "GET /api/ash/llm-configuration-tags" do
    test "shows foreign tags visible through shared bots but editable_only keeps own tags" do
      %{user: owner} = user_fixture()
      %{user: recipient} = recipient_fixture = user_fixture()
      %{group: group} = user_group_fixture(%{users: [owner, recipient]})
      owner_tag = create_configuration_tag!(owner)
      recipient_tag = create_configuration_tag!(recipient)
      bot = create_bot!(owner)

      create!(
        BotCompatibleConfigurationTag,
        %{bot_id: bot.id, llm_configuration_tag_id: owner_tag.id},
        owner
      )

      share_bot!(owner, bot, group)

      foreign = api_get!(recipient_fixture, "/api/ash/llm-configuration-tags/#{owner_tag.id}")
      assert response_id(foreign) == owner_tag.id

      editable =
        api_get!(
          recipient_fixture,
          "/api/ash/llm-configuration-tags?sort=name&editable_only=true"
        )

      assert ids_from_data(editable) == [recipient_tag.id]
    end
  end

  defp json_attributes(settings) do
    Map.new(settings, fn
      {key, value} when is_atom(value) and value not in [nil, true, false] ->
        {Atom.to_string(key), Atom.to_string(value)}

      {key, value} ->
        {Atom.to_string(key), value}
    end)
  end

  defp assert_settings(response, settings) do
    attributes = response["data"]["attributes"]
    refute Map.has_key?(attributes, "supports_steering")

    for {key, value} <- json_attributes(settings) do
      assert attributes[key] == value, "#{key}: #{inspect(attributes[key])}"
    end
  end

  defp assert_stored_settings(id, actor, settings) do
    configuration = Ash.get!(LlmConfiguration, id, actor: actor)
    assert Map.take(configuration, Map.keys(settings)) == settings
  end
end
