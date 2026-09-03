defmodule IntellectualClub.Tools.Changes.MergeSecretsPatch do
  @moduledoc """
  Applies write-only patch semantics to driver secrets and persists the result
  through managed secret bindings.

  Keys omitted from a patch remain unchanged, empty values remove keys, and
  aliases are normalized according to the selected driver's secret schema.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias IntellectualClub.Secrets.DriverSecrets

  @impl true
  def change(changeset, _opts, _context) do
    if Changeset.changing_attribute?(changeset, :secrets) do
      patch = Changeset.get_attribute(changeset, :secrets)
      tool_instance = tool_instance_for_patch(changeset)

      case DriverSecrets.values(tool_instance) do
        {:ok, current} ->
          merged = DriverSecrets.apply_patch(tool_instance, current, patch)

          changeset
          |> Changeset.force_change_attribute(:secrets, %{})
          |> Changeset.set_private_argument(:effective_driver_secrets, merged)
          |> Changeset.after_action(fn changeset, tool_instance ->
            actor = changeset.context[:private][:actor]

            case DriverSecrets.sync(tool_instance, merged, actor) do
              {:ok, _tool_instance} -> {:ok, %{tool_instance | secrets: merged}}
              {:error, error} -> {:error, error}
            end
          end)

        {:error, message} ->
          Changeset.add_error(changeset, field: :secrets, message: message)
      end
    else
      changeset
    end
  end

  defp tool_instance_for_patch(changeset) do
    type = Changeset.get_attribute(changeset, :type) || Map.get(changeset.data, :type)
    %{changeset.data | type: type}
  end
end
