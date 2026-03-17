defmodule IntellectualClub.Generation.AutoRetryTest do
  use IntellectualClub.DataCase, async: false

  alias IntellectualClub.Chat.Chat
  alias IntellectualClub.Chat.ChatMessage
  alias IntellectualClub.Chat.Threads
  alias IntellectualClub.Generation.Supervisor, as: GenerationSupervisor
  alias IntellectualClub.Llm.LlmConfiguration
  alias IntellectualClub.Llm.LlmProvider

  test "generation retries transient provider errors by recreating the step" do
    %{user: actor} = user_fixture()

    provider =
      LlmProvider
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Retry provider",
          type: :responses,
          auth_method: :api_key,
          base_url: "http://127.0.0.1:9",
          api_key: "test-key"
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
          model_name: "gpt-4.1-mini",
          note: "",
          parameters: %{},
          timeout_seconds: 1
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    chat =
      Chat
      |> Ash.Changeset.for_create(
        :create,
        %{
          title: "Auto retry",
          note: "",
          variables: %{},
          llm_configuration_id: configuration.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, _user_message} =
      Threads.add_message_to_end(chat, :user, "Please fail on transport", actor: actor)

    {:ok, context} = GenerationSupervisor.start_generation(chat.id, actor: actor)

    message = wait_for_status!(context.message_id, actor, [:error], 12_000)

    step =
      message.steps
      |> List.wrap()
      |> Enum.max_by(& &1.sequence)

    assert step.sequence == 1
    assert step.id != context.step_id
    assert message.status == :error
  end

  defp wait_for_status!(message_id, actor, wanted, timeout_ms)
       when is_integer(message_id) and is_list(wanted) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_status(message_id, actor, wanted, deadline)
  end

  defp do_wait_for_status(message_id, actor, wanted, deadline) do
    message =
      Ash.get!(ChatMessage, message_id,
        actor: actor,
        load: [steps: [items: [:contents]]]
      )

    if message.status in wanted do
      message
    else
      if System.monotonic_time(:millisecond) < deadline do
        # Avoid hammering the shared sandbox connection while generation runs in
        # other processes.
        Process.sleep(100)
        do_wait_for_status(message_id, actor, wanted, deadline)
      else
        flunk("Generation did not reach expected status")
      end
    end
  end
end
