defmodule IntellectualClub.Llm.Providers.StandardParametersTest do
  use ExUnit.Case, async: true

  alias IntellectualClub.Llm.Providers.AnthropicMessages
  alias IntellectualClub.Llm.Providers.Common.MissingProvider
  alias IntellectualClub.Llm.Providers.Demo
  alias IntellectualClub.Llm.Providers.GoogleInteractions
  alias IntellectualClub.Llm.Providers.NvidiaBuildChatCompletion
  alias IntellectualClub.Llm.Providers.OpenRouterChatCompletion
  alias IntellectualClub.Llm.Providers.Responses
  alias IntellectualClub.Llm.Providers.ResponsesWss
  alias IntellectualClub.TestSupport.LlmProviders.SelfContainedTestProvider

  @efforts [:none, :minimal, :low, :medium, :high, :xhigh, :max]

  test "default settings leave advanced parameters unchanged" do
    parameters = %{
      "temperature" => 0.7,
      "reasoning" => %{"effort" => "high", "summary" => "detailed"},
      "custom" => %{"nested" => true}
    }

    settings = %{temperature: nil, reasoning_effort: nil}

    for provider <- [
          Responses,
          ResponsesWss,
          OpenRouterChatCompletion,
          NvidiaBuildChatCompletion,
          GoogleInteractions,
          AnthropicMessages,
          Demo,
          MissingProvider,
          SelfContainedTestProvider
        ] do
      assert provider.apply_standard_parameters(parameters, settings) == parameters
    end
  end

  test "hosted web search uses each provider wire format and preserves manual configuration" do
    settings = %{temperature: nil, reasoning_effort: nil, web_search_enabled: true}

    assert Responses.apply_standard_parameters(%{}, settings)["tools"] == [
             %{"type" => "web_search"}
           ]

    assert ResponsesWss.apply_standard_parameters(%{}, settings)["tools"] == [
             %{"type" => "web_search"}
           ]

    assert OpenRouterChatCompletion.apply_standard_parameters(%{}, settings)["tools"] == [
             %{"type" => "openrouter:web_search"}
           ]

    assert GoogleInteractions.apply_standard_parameters(%{}, settings)["tools"] == [
             %{"type" => "google_search"}
           ]

    assert AnthropicMessages.apply_standard_parameters(%{}, settings)["tools"] == [
             %{"type" => "web_search_20250305", "name" => "web_search"}
           ]

    manual_responses_tool = %{
      "type" => "web_search",
      "filters" => %{"allowed_domains" => ["openai.com"]}
    }

    assert Responses.apply_standard_parameters(%{"tools" => [manual_responses_tool]}, settings)[
             "tools"
           ] == [manual_responses_tool]

    manual_anthropic_tool = %{
      "type" => "web_search_20250305",
      "name" => "web_search",
      "max_uses" => 3
    }

    assert AnthropicMessages.apply_standard_parameters(
             %{"tools" => [manual_anthropic_tool]},
             settings
           )["tools"] == [manual_anthropic_tool]
  end

  test "unsupported providers ignore hosted web search" do
    parameters = %{"custom" => true}
    settings = %{temperature: nil, reasoning_effort: nil, web_search_enabled: true}

    for provider <- [NvidiaBuildChatCompletion, Demo, MissingProvider, SelfContainedTestProvider] do
      assert provider.apply_standard_parameters(parameters, settings) == parameters
    end
  end

  test "NVIDIA Build writes top-level reasoning effort and removes OpenRouter reasoning" do
    parameters = %{
      "temperature" => 1.5,
      "reasoning" => %{"effort" => "old"},
      "reasoning_effort" => "old",
      "reasoning_budget" => 2_048,
      "custom" => "kept"
    }

    for effort <- @efforts do
      result =
        NvidiaBuildChatCompletion.apply_standard_parameters(parameters, %{
          temperature: 0,
          reasoning_effort: effort
        })

      assert result["temperature"] == 0
      assert result["reasoning_effort"] == Atom.to_string(effort)
      assert result["reasoning_budget"] == 2_048
      assert result["custom"] == "kept"
      refute Map.has_key?(result, "reasoning")
    end
  end

  test "responses writes temperature and every effort literally while preserving reasoning fields" do
    parameters = %{
      "temperature" => 1.5,
      "reasoning" => %{"effort" => "old", "summary" => "detailed"}
    }

    for effort <- @efforts do
      settings = %{temperature: 0, reasoning_effort: effort}
      result = Responses.apply_standard_parameters(parameters, settings)

      assert result["temperature"] == 0

      assert result["reasoning"] == %{
               "effort" => Atom.to_string(effort),
               "summary" => "detailed"
             }

      assert ResponsesWss.apply_standard_parameters(parameters, settings) == result
    end
  end

  test "openrouter replaces conflicting reasoning controls and preserves neighboring fields" do
    parameters = %{
      "temperature" => 1.5,
      "reasoning_effort" => "old",
      "reasoning" => %{
        "effort" => "old",
        "max_tokens" => 2_048,
        "enabled" => true,
        "exclude" => true,
        "custom" => "kept"
      }
    }

    for effort <- @efforts do
      result =
        OpenRouterChatCompletion.apply_standard_parameters(parameters, %{
          temperature: 0,
          reasoning_effort: effort
        })

      assert result["temperature"] == 0
      refute Map.has_key?(result, "reasoning_effort")

      assert result["reasoning"] == %{
               "effort" => Atom.to_string(effort),
               "exclude" => true,
               "custom" => "kept"
             }
    end
  end

  test "google writes generation config and removes conflicting thinking budget" do
    parameters = %{
      "temperature" => 1.5,
      "thinking_level" => "high",
      "thinking_budget" => 4_096,
      "generation_config" => %{
        "temperature" => 1.2,
        "thinking_level" => "medium",
        "thinking_budget" => 2_048,
        "top_p" => 0.9
      },
      "custom" => "kept"
    }

    for effort <- @efforts do
      result =
        GoogleInteractions.apply_standard_parameters(parameters, %{
          temperature: 0,
          reasoning_effort: effort
        })

      refute Map.has_key?(result, "temperature")
      refute Map.has_key?(result, "thinking_level")
      refute Map.has_key?(result, "thinking_budget")
      assert result["custom"] == "kept"

      assert result["generation_config"] == %{
               "temperature" => 0,
               "thinking_level" => Atom.to_string(effort),
               "top_p" => 0.9
             }
    end
  end

  test "anthropic uses adaptive thinking for literal efforts without endpoint branching" do
    parameters = %{
      "temperature" => 1,
      "thinking" => %{"type" => "enabled", "budget_tokens" => 2_048},
      "output_config" => %{"effort" => "old", "verbosity" => "verbose"}
    }

    for effort <- @efforts -- [:none] do
      result =
        AnthropicMessages.apply_standard_parameters(parameters, %{
          temperature: 0.4,
          reasoning_effort: effort
        })

      assert result["temperature"] == 0.4
      assert result["thinking"] == %{"type" => "adaptive"}

      assert result["output_config"] == %{
               "effort" => Atom.to_string(effort),
               "verbosity" => "verbose"
             }
    end
  end

  test "anthropic disables thinking for none and removes only output effort" do
    parameters = %{
      "thinking" => %{"type" => "adaptive"},
      "output_config" => %{"effort" => "high", "verbosity" => "verbose"}
    }

    result =
      AnthropicMessages.apply_standard_parameters(parameters, %{
        temperature: nil,
        reasoning_effort: :none
      })

    assert result["thinking"] == %{"type" => "disabled"}
    assert result["output_config"] == %{"verbosity" => "verbose"}

    result_without_output_config =
      AnthropicMessages.apply_standard_parameters(%{}, %{
        temperature: nil,
        reasoning_effort: :none
      })

    assert result_without_output_config == %{"thinking" => %{"type" => "disabled"}}
  end

  test "no-op providers ignore explicit standard settings" do
    parameters = %{"temperature" => 0.7, "custom" => true}
    settings = %{temperature: 0, reasoning_effort: :max}

    for provider <- [Demo, MissingProvider, SelfContainedTestProvider] do
      assert provider.apply_standard_parameters(parameters, settings) == parameters
    end
  end
end
