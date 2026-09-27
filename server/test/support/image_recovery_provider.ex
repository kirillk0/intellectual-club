defmodule IntellectualClub.TestSupport.ImageRecoveryProvider do
  @moduledoc false
  @behaviour IntellectualClub.Llm.Providers.Common.ProviderType
  alias IntellectualClub.Llm.Providers.{Demo, Responses}

  def type, do: "image_recovery_test"
  def label, do: "Image recovery test"
  def metadata, do: Demo.metadata() |> Map.put(:type, type()) |> Map.put(:label, label())
  def validate_provider(_provider, _opts), do: :ok
  def list_models(_provider), do: {:ok, []}
  def supports_cache_control?, do: false
  def apply_standard_parameters(parameters, _settings), do: parameters
  def prepare_request(request, _context), do: request
  defdelegate map_request_images(request, acc, mapper), to: Responses
  defdelegate build_initial_request(opts), to: Responses
  defdelegate build_followup_request(opts), to: Responses
  defdelegate inject_steering(request, items, context), to: Responses
  defdelegate request_snapshot(request), to: Responses

  def stream_generate(opts, emit) do
    {:ok, _wire} =
      IntellectualClub.Generation.RequestImages.hydrate(
        opts.request_payload,
        opts.request_step_id,
        mapper: &map_request_images/3,
        cache: Map.get(opts, :image_cache, %{}),
        on_cache: Map.get(opts, :image_cache_update)
      )

    emit.({:trace, {:set_text, "answer", :answer, 1, "Recovered image."}})
    emit.({:response_complete, %{raw_response: %{"id" => "image-recovery", "output" => []}}})
    :ok
  end
end
