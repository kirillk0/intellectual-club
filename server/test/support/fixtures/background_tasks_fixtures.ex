defmodule IntellectualClub.BackgroundTasksFixtures do
  @moduledoc """
  Fixtures for background tasks.
  """

  import IntellectualClub.Fixtures

  alias IntellectualClub.BackgroundTasks.BackgroundTask

  @doc """
  Creates a background task. Defaults describe a queued SSH command owned by
  `actor`: `kind: "ssh_command"`, `adapter: "ssh"`, `status: :queued`,
  `function_name: "run_command"`, `arguments: %{"command" => "echo test"}`,
  `execution_context: %{"owner_id" => actor.id}`, `runner_ref: %{}`.

  Options taken from `attrs`:

    * `:generation` — a generation (assistant) message; its chat and message ids
      are added to `execution_context` and used as `source_chat_id` /
      `source_message_id`;
    * `:cancel_requested` — when `true`, the task is updated with
      `cancel_requested: true` after creation.
  """
  def create_background_task!(actor, attrs \\ %{}) do
    {options, attrs} = Map.split(to_attrs(attrs), [:generation, :cancel_requested])

    defaults =
      %{
        kind: "ssh_command",
        adapter: "ssh",
        status: :queued,
        function_name: "run_command",
        arguments: %{"command" => "echo test"},
        execution_context: %{"owner_id" => actor.id},
        runner_ref: %{}
      }
      |> put_generation(options[:generation])

    task = create!(BackgroundTask, Map.merge(defaults, attrs), actor)

    if options[:cancel_requested] do
      task
      |> Ash.Changeset.for_update(:update_state, %{cancel_requested: true}, actor: actor)
      |> Ash.update!(actor: actor)
    else
      task
    end
  end

  defp put_generation(defaults, nil), do: defaults

  defp put_generation(defaults, generation) do
    defaults
    |> Map.update!(
      :execution_context,
      &Map.merge(&1, %{
        "chat_id" => generation.chat_id,
        "message_id" => generation.id,
        "assistant_message_id" => generation.id
      })
    )
    |> Map.merge(%{source_chat_id: generation.chat_id, source_message_id: generation.id})
  end
end
