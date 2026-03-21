defmodule IntellectualClub.Chat.Changes.SetFinishedAtFromStatus do
  @moduledoc """
  Sets `finished_at` when the resulting status is terminal.
  """

  use Ash.Resource.Change

  @default_terminal_statuses [:done, :canceled, :error]

  @impl true
  def change(changeset, opts, _context) do
    terminal_statuses = Keyword.get(opts, :terminal_statuses, @default_terminal_statuses)

    finished_at =
      case Ash.Changeset.get_attribute(changeset, :status) do
        status when not is_nil(status) ->
          if Enum.member?(terminal_statuses, status), do: DateTime.utc_now(), else: nil

        _other ->
          nil
      end

    Ash.Changeset.change_attribute(changeset, :finished_at, finished_at)
  end
end
