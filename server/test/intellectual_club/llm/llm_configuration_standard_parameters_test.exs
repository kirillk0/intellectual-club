defmodule IntellectualClub.Llm.LlmConfigurationStandardParametersTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider

  @reasoning_efforts [:none, :minimal, :low, :medium, :high, :xhigh, :max]

  test "standard parameters default to nil" do
    %{user: actor} = user_fixture()
    provider = create_provider!(actor)
    configuration = create_configuration!(actor, provider)

    assert is_nil(configuration.temperature)
    assert is_nil(configuration.reasoning_effort)
    assert configuration.web_search_enabled == false
    assert is_nil(configuration.cold_input_price_per_million_tokens)
    assert is_nil(configuration.cached_input_price_per_million_tokens)
    assert is_nil(configuration.output_price_per_million_tokens)
  end

  test "manual pricing persists as a complete set and can be cleared" do
    %{user: actor} = user_fixture()
    provider = create_provider!(actor)

    configuration =
      create_configuration!(actor, provider, %{
        cold_input_price_per_million_tokens: 1.25,
        cached_input_price_per_million_tokens: 0,
        output_price_per_million_tokens: 8.5
      })

    assert configuration.cold_input_price_per_million_tokens == 1.25
    assert configuration.cached_input_price_per_million_tokens == 0.0
    assert configuration.output_price_per_million_tokens == 8.5

    cleared =
      configuration
      |> Ash.Changeset.for_update(
        :update,
        %{
          cold_input_price_per_million_tokens: nil,
          cached_input_price_per_million_tokens: nil,
          output_price_per_million_tokens: nil
        },
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert is_nil(cleared.cold_input_price_per_million_tokens)
    assert is_nil(cleared.cached_input_price_per_million_tokens)
    assert is_nil(cleared.output_price_per_million_tokens)
  end

  test "manual pricing rejects partial and negative values" do
    %{user: actor} = user_fixture()
    provider = create_provider!(actor)

    assert {:error, %Ash.Error.Invalid{}} =
             LlmConfiguration
             |> Ash.Changeset.for_create(
               :create,
               %{
                 provider_id: provider.id,
                 model_name: "partial-pricing-model",
                 parameters: %{},
                 cold_input_price_per_million_tokens: 1.0
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    assert {:error, %Ash.Error.Invalid{}} =
             LlmConfiguration
             |> Ash.Changeset.for_create(
               :create,
               %{
                 provider_id: provider.id,
                 model_name: "negative-pricing-model",
                 parameters: %{},
                 cold_input_price_per_million_tokens: -0.01,
                 cached_input_price_per_million_tokens: 0.5,
                 output_price_per_million_tokens: 2.0
               },
               actor: actor
             )
             |> Ash.create(actor: actor)
  end

  test "standard parameters persist, accept all effort levels, and can be reset" do
    %{user: actor} = user_fixture()
    provider = create_provider!(actor)

    configuration =
      create_configuration!(actor, provider, %{
        temperature: 0,
        reasoning_effort: :minimal,
        web_search_enabled: true
      })

    assert configuration.temperature == 0.0
    assert configuration.reasoning_effort == :minimal
    assert configuration.web_search_enabled == true

    configuration =
      Enum.reduce(@reasoning_efforts, configuration, fn reasoning_effort, current ->
        updated =
          current
          |> Ash.Changeset.for_update(
            :update,
            %{
              temperature: 2,
              reasoning_effort: reasoning_effort,
              web_search_enabled: true
            },
            actor: actor
          )
          |> Ash.update!(actor: actor)

        reloaded = Ash.get!(LlmConfiguration, updated.id, actor: actor)
        assert reloaded.temperature == 2.0
        assert reloaded.reasoning_effort == reasoning_effort
        assert reloaded.web_search_enabled == true
        reloaded
      end)

    reset =
      configuration
      |> Ash.Changeset.for_update(
        :update,
        %{temperature: nil, reasoning_effort: nil, web_search_enabled: false},
        actor: actor
      )
      |> Ash.update!(actor: actor)

    assert is_nil(reset.temperature)
    assert is_nil(reset.reasoning_effort)
    assert reset.web_search_enabled == false
  end

  test "standard parameter constraints reject invalid values" do
    %{user: actor} = user_fixture()
    provider = create_provider!(actor)
    configuration = create_configuration!(actor, provider)

    assert {:error, %Ash.Error.Invalid{}} =
             configuration
             |> Ash.Changeset.for_update(:update, %{temperature: -0.01}, actor: actor)
             |> Ash.update(actor: actor)

    assert {:error, %Ash.Error.Invalid{}} =
             configuration
             |> Ash.Changeset.for_update(:update, %{temperature: 2.01}, actor: actor)
             |> Ash.update(actor: actor)

    assert {:error, %Ash.Error.Invalid{}} =
             configuration
             |> Ash.Changeset.for_update(
               :update,
               %{reasoning_effort: :unsupported},
               actor: actor
             )
             |> Ash.update(actor: actor)
  end

  defp create_provider!(actor) do
    LlmProvider
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Standard parameters provider",
        type: :demo,
        auth_method: :api_key,
        base_url: "http://localhost",
        api_key: "test"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end

  defp create_configuration!(actor, provider, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          provider_id: provider.id,
          model_name: "standard-parameters-model",
          parameters: %{}
        },
        attrs
      )

    LlmConfiguration
    |> Ash.Changeset.for_create(:create, attrs, actor: actor)
    |> Ash.create!(actor: actor)
  end
end
