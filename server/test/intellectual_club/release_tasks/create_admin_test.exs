defmodule IntellectualClub.ReleaseTasks.CreateAdminTest do
  use IntellectualClub.DataCase, async: true

  import ExUnit.CaptureIO

  alias IntellectualClub.Accounts.AdminProvisioning
  alias IntellectualClub.ReleaseTasks.CreateAdmin

  test "reads JSON credentials from stdin without writing the password" do
    password = "json-password-1234"

    payload =
      Jason.encode!(%{
        username: "json_admin",
        password: password,
        password_confirmation: password
      })

    parent = self()

    output =
      capture_io(payload, fn ->
        assert {:ok, %{username: "json_admin", is_admin: true}} =
                 CreateAdmin.run(["--json-stdin"],
                   provisioner: fn attributes ->
                     send(parent, {:attributes, attributes})
                     {:ok, %{username: attributes.username, is_admin: true}}
                   end
                 )
      end)

    assert output == ""
    assert_received {:attributes, %{password: ^password, password_confirmation: ^password}}
    refute output =~ password
  end

  test "rejects mismatched passwords before provisioning" do
    payload =
      Jason.encode!(%{
        username: "json_admin",
        password: "first-password",
        password_confirmation: "second-password"
      })

    output =
      capture_io(payload, fn ->
        assert {:error, :password_mismatch, "Passwords do not match."} =
                 CreateAdmin.run(["--json-stdin"],
                   provisioner: fn _attributes -> flunk("provisioner must not be called") end
                 )
      end)

    assert output == ""
  end

  test "reads the interactive wrapper line protocol from stdin" do
    password = "line-password-1234"
    parent = self()

    output =
      capture_io("line_admin\n#{password}\n#{password}\n", fn ->
        assert {:ok, %{username: "line_admin"}} =
                 CreateAdmin.run(["--line-stdin"],
                   provisioner: fn attributes ->
                     send(parent, {:attributes, attributes})
                     {:ok, %{username: attributes.username}}
                   end
                 )
      end)

    assert output == ""
    assert_received {:attributes, %{password: ^password, password_confirmation: ^password}}
  end

  test "returns a clear error when line input ends early" do
    output =
      capture_io("line_admin\n", fn ->
        assert {:error, :invalid_input, "Input ended before all fields were provided."} =
                 CreateAdmin.run(["--line-stdin"])
      end)

    assert output == ""
  end

  test "returns a clear error for malformed JSON" do
    output =
      capture_io("not-json", fn ->
        assert {:error, :invalid_input, "Expected a JSON object on stdin."} =
                 CreateAdmin.run(["--json-stdin"])
      end)

    assert output == ""
  end

  test "normalizes duplicate usernames" do
    payload =
      Jason.encode!(%{
        username: "existing_admin",
        password: "password-1234",
        password_confirmation: "password-1234"
      })

    capture_io(payload, fn ->
      assert {:error, :username_taken, "Username already exists."} =
               CreateAdmin.run(["--json-stdin"],
                 provisioner: fn _attributes -> {:error, :username_taken} end
               )
    end)
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
