defmodule IntellectualClub.Tools.Changes.MigrateBraveSearch do
  @moduledoc "Transforms legacy Brave instances while preserving their identity and credentials."
  use Ash.Resource.Change
  alias IntellectualClub.Secrets.DriverSecrets
  alias IntellectualClub.Tools.Drivers.NativeWebSearch

  @impl true
  def change(changeset, _, _) do
    if changeset.data.type == "native-brave-search" do
      case DriverSecrets.values(changeset.data) do
        {:ok, secrets} ->
          config =
            Map.merge(
              %{"user_agent" => "IntellectualClubBraveSearch/0.1"},
              changeset.data.config || %{}
            )

          changeset
          |> Ash.Changeset.force_change_attribute(:type, NativeWebSearch.type())
          |> Ash.Changeset.force_change_attribute(
            :config,
            NativeWebSearch.normalize_config(config)
          )
          |> Ash.Changeset.force_change_attribute(:secrets, secrets)

        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :secrets, message: message)
      end
    else
      changeset
    end
  end
end
