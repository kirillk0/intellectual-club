defmodule IntellectualClub.Chat.Changes.SnapshotMessageConfiguration do
  @moduledoc """
  Captures the configuration label when an assistant message is created.
  Internal copies preserve the source snapshot, even without a live configuration.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Llm.LlmConfiguration

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      configuration_id = Changeset.get_attribute(changeset, :llm_configuration_id)
      snapshot = Changeset.get_attribute(changeset, :llm_configuration_label_snapshot)

      cond do
        Changeset.get_attribute(changeset, :role) != :assistant ->
          Changeset.force_change_attribute(changeset, :llm_configuration_label_snapshot, nil)

        not is_nil(snapshot) or is_nil(configuration_id) ->
          changeset

        true ->
          actor = changeset.context[:private][:actor]

          case Ash.get(LlmConfiguration, configuration_id, actor: actor) do
            {:ok, %LlmConfiguration{} = configuration} ->
              note = String.trim(configuration.note || "")
              label = configuration.model_name
              label = if note == "", do: label, else: "#{label} (#{note})"

              Changeset.force_change_attribute(
                changeset,
                :llm_configuration_label_snapshot,
                label
              )

            _ ->
              Changeset.add_error(changeset,
                field: :llm_configuration_id,
                message: "is invalid or not accessible"
              )
          end
      end
    end)
  end
end
