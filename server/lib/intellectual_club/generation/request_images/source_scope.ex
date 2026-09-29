defmodule IntellectualClub.Generation.RequestImages.SourceScope do
  @moduledoc false

  alias IntellectualClub.Chat.{Chat, ForkHistory}
  alias IntellectualClub.Generation.History

  require Ash.Query

  def validate(step, scope, chat_scope_ids) do
    cond do
      not is_integer(scope.owner_id) or step.owner_id != scope.owner_id ->
        {:error, :request_image_source_out_of_scope}

      step.chat_message.chat_id in chat_scope_ids ->
        :ok

      true ->
        validate_inherited_source(step.id, scope.owner_id, chat_scope_ids)
    end
  end

  defp validate_inherited_source(_step_id, _owner_id, []),
    do: {:error, :request_image_source_out_of_scope}

  defp validate_inherited_source(step_id, owner_id, chat_scope_ids) do
    actor = %{id: owner_id}

    with {:ok, forks} <-
           Chat
           |> Ash.Query.filter(
             id in ^chat_scope_ids and owner_id == ^owner_id and not is_nil(fork_source_step_id)
           )
           |> Ash.Query.select([:id])
           |> Ash.read(actor: actor) do
      Enum.reduce_while(forks, {:error, :request_image_source_out_of_scope}, fn fork, denied ->
        case ForkHistory.prefix(fork.id, actor) do
          {:ok, messages} ->
            # Match ContentFiles: a shared, mixed-owner inherited prefix does not
            # grant file access, even when one of its earlier steps is owned.
            visible? =
              Enum.all?(messages, &(&1.owner_id == owner_id)) and
                Enum.any?(messages, fn message ->
                  Enum.any?(History.steps(message), &(&1.id == step_id))
                end)

            if visible?, do: {:halt, :ok}, else: {:cont, denied}

          {:error, :fork_context_unavailable} ->
            {:cont, denied}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    end
  end
end
