defmodule IntellectualClub.Accounts.Changes.ValidatePasswordChange do
  @moduledoc """
  Validates current password and basic new-password rules for self-service updates.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias AshAuthentication.Info

  @impl true
  def change(changeset, opts, _context) do
    strategy_name = Keyword.get(opts, :strategy_name, :password)

    Changeset.before_action(changeset, fn changeset ->
      case Info.strategy(changeset.resource, strategy_name) do
        {:ok, strategy} ->
          password_field = strategy.password_field
          hashed_password_field = strategy.hashed_password_field

          current_password = to_string(Changeset.get_argument(changeset, :current_password) || "")
          new_password = to_string(Changeset.get_argument(changeset, password_field) || "")
          hashed_password = Changeset.get_data(changeset, hashed_password_field)

          changeset =
            if String.trim(current_password) == "" do
              Changeset.add_error(changeset,
                field: :current_password,
                message: "Current password is required."
              )
            else
              changeset
            end

          changeset =
            if String.trim(current_password) != "" and
                 not strategy.hash_provider.valid?(current_password, hashed_password) do
              Changeset.add_error(changeset,
                field: :current_password,
                message: "Current password is incorrect."
              )
            else
              changeset
            end

          if String.trim(new_password) != "" and new_password == current_password do
            Changeset.add_error(changeset,
              field: password_field,
              message: "New password must be different from current password."
            )
          else
            changeset
          end

        :error ->
          Changeset.add_error(changeset, message: "Password strategy is not configured")
      end
    end)
  end
end
