defmodule IntellectualClub.Generation.ProviderAdapterResolver do
  @moduledoc false

  alias IntellectualClub.Generation.Adapters.DemoAdapter
  alias IntellectualClub.Generation.Adapters.OpenRouterChatCompletionAdapter
  alias IntellectualClub.Generation.Adapters.ResponsesAdapter

  def for_provider_type(nil), do: DemoAdapter
  def for_provider_type(:demo), do: DemoAdapter
  def for_provider_type(:openrouter_chat_completion), do: OpenRouterChatCompletionAdapter
  def for_provider_type(:openai_compatible), do: OpenRouterChatCompletionAdapter
  def for_provider_type(:responses), do: ResponsesAdapter

  def for_provider_type(other) do
    raise ArgumentError, "Unsupported provider type: #{inspect(other)}"
  end
end
