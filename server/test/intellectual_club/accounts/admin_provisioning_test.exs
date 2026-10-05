defmodule IntellectualClub.Accounts.AdminProvisioningTest do
  use IntellectualClub.DataCase, async: true

  import ExUnit.CaptureIO

  alias IntellectualClub.Accounts.{AdminProvisioning, User}
  alias IntellectualClub.ReleaseTasks.CreateAdmin

  describe "AdminProvisioning.create_admin/1" do
    test "creates an administrator that can authenticate" do
      username = "provisioned_admin_#{System.unique_integer([:positive])}"
      password = "provisioned-password-1234"

      assert {:ok, %User{username: ^username, is_admin: true} = user} =
               AdminProvisioning.create_admin(%{
                 username: username,
                 password: password,
                 password_confirmation: password
               })

      strategy = AshAuthentication.Info.strategy!(User, :password)

      assert {:ok, %User{id: user_id}} =
               AshAuthentication.Strategy.action(strategy, :sign_in, %{
                 "username" => username,
                 "password" => password
               })

      assert user_id == user.id
    end

    test "creates another administrator when administrators already exist" do
      %{user: existing_admin} = user_fixture(%{is_admin: true})
      username = "additional_admin_#{System.unique_integer([:positive])}"
      password = "additional-password-1234"

      assert {:ok, %User{username: ^username, is_admin: true}} =
               AdminProvisioning.create_admin(%{
                 username: username,
                 password: password,
                 password_confirmation: password
               })

      assert {:ok, %User{is_admin: true}} = Ash.get(User, existing_admin.id, authorize?: false)
    end

    test "does not modify an existing user" do
      original_password = "original-password-1234"

      %{user: existing_user} =
        user_fixture(%{is_admin: false, password: original_password})

      assert {:error, :username_taken} =
               AdminProvisioning.create_admin(%{
                 username: existing_user.username,
                 password: "replacement-password-1234",
                 password_confirmation: "replacement-password-1234"
               })

      assert {:ok, %User{is_admin: false}} = Ash.get(User, existing_user.id, authorize?: false)

      strategy = AshAuthentication.Info.strategy!(User, :password)

      assert {:ok, %User{id: user_id}} =
               AshAuthentication.Strategy.action(strategy, :sign_in, %{
                 "username" => existing_user.username,
                 "password" => original_password
               })

      assert user_id == existing_user.id
    end
  end

  describe "ReleaseTasks.CreateAdmin.run/2" do
    for {flag, input} <- [
          {"--json-stdin",
           Jason.encode!(%{
             username: "stdin_admin",
             password: "stdin-password-1234",
             password_confirmation: "stdin-password-1234"
           })},
          {"--line-stdin", "stdin_admin\nstdin-password-1234\nstdin-password-1234\n"}
        ] do
      @flag flag
      @input input

      test "#{flag} passes credentials to the provisioner without writing the password" do
        password = "stdin-password-1234"
        parent = self()

        output =
          capture_io(@input, fn ->
            assert {:ok, %{username: "stdin_admin", is_admin: true}} =
                     CreateAdmin.run([@flag],
                       provisioner: fn attributes ->
                         send(parent, {:attributes, attributes})
                         {:ok, %{username: attributes.username, is_admin: true}}
                       end
                     )
          end)

        assert output == ""

        assert_received {:attributes,
                         %{
                           username: "stdin_admin",
                           password: ^password,
                           password_confirmation: ^password
                         }}
      end
    end

    for {name, flag, input, provisioner, expected} <- [
          {"rejects mismatched passwords before provisioning", "--json-stdin",
           Jason.encode!(%{
             username: "json_admin",
             password: "first-password",
             password_confirmation: "second-password"
           }), :never, {:error, :password_mismatch, "Passwords do not match."}},
          {"returns a clear error when line input ends early", "--line-stdin", "line_admin\n",
           :never, {:error, :invalid_input, "Input ended before all fields were provided."}},
          {"returns a clear error for malformed JSON", "--json-stdin", "not-json", :never,
           {:error, :invalid_input, "Expected a JSON object on stdin."}},
          {"normalizes duplicate usernames", "--json-stdin",
           Jason.encode!(%{
             username: "existing_admin",
             password: "password-1234",
             password_confirmation: "password-1234"
           }), {:error, :username_taken}, {:error, :username_taken, "Username already exists."}}
        ] do
      @flag flag
      @input input
      @provisioner provisioner
      @expected expected

      test name do
        provisioner =
          case @provisioner do
            :never -> fn _attributes -> flunk("provisioner must not be called") end
            result -> fn _attributes -> result end
          end

        output =
          capture_io(@input, fn ->
            assert CreateAdmin.run([@flag], provisioner: provisioner) == @expected
          end)

        assert output == ""
      end
    end

    test "returns existing validation errors for invalid values" do
      payload =
        Jason.encode!(%{
          username: "ab",
          password: "password-1234",
          password_confirmation: "password-1234"
        })

      capture_io(payload, fn ->
        assert {:error, :validation_failed, message} =
                 CreateAdmin.run(["--json-stdin"],
                   provisioner: &AdminProvisioning.create_admin/1
                 )

        assert message =~ "length must be greater than or equal to 3"
      end)
    end
  end
end
