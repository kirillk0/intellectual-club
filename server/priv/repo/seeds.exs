# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     IntellectualClub.Repo.insert!(%IntellectualClub.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias IntellectualClub.Accounts.User

require Ash.Query

admin_username = System.get_env("IC_SEED_ADMIN_USERNAME")
admin_password = System.get_env("IC_SEED_ADMIN_PASSWORD")

if admin_username && admin_password do
  existing_admin =
    User
    |> Ash.Query.filter(username == ^admin_username)
    |> Ash.read_one!(authorize?: false)

  if existing_admin do
    existing_admin
    |> Ash.Changeset.for_update(:update, %{is_admin: true}, authorize?: false)
    |> Ash.update!()

    existing_admin
    |> Ash.Changeset.for_update(
      :reset_password,
      %{password: admin_password, password_confirmation: admin_password},
      authorize?: false
    )
    |> Ash.update!()

    IO.puts("Seed admin user updated: #{admin_username}")
  else
    User
    |> Ash.Changeset.for_create(
      :create,
      %{
        username: admin_username,
        is_admin: true,
        password: admin_password,
        password_confirmation: admin_password
      },
      authorize?: false
    )
    |> Ash.create!()

    IO.puts("Seed admin user created: #{admin_username}")
  end
else
  IO.puts("""
  Admin seed user not created.

  To create an initial admin user for development, set:
    - IC_SEED_ADMIN_USERNAME
    - IC_SEED_ADMIN_PASSWORD
  """)
end
