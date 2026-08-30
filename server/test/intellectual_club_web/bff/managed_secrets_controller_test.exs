defmodule IntellectualClubWeb.Bff.ManagedSecretsControllerTest do
  use IntellectualClubWeb.ConnCase, async: false

  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Secrets.{Crypto, KnowledgeBlockSecret, Secret, ToolInstanceSecret}
  alias IntellectualClub.Tools.ToolInstance

  require Ash.Query

  test "secret attachments are parent-scoped, write-only, editable, and deleted with their row",
       %{
         conn: conn
       } do
    %{user: actor, password: password} = user_fixture()

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(:create, %{name: "GitLab", content: "Use GitLab."},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/knowledge-blocks/#{block.id}/secrets", %{
        "name" => "GitLab token",
        "description" => "Token for GitLab API",
        "env_name" => "GITLAB_TOKEN",
        "value" => "must-never-be-returned"
      })
      |> json_response(200)

    assert %{
             "id" => attachment_id,
             "name" => "GitLab token",
             "description" => "Token for GitLab API",
             "env_name" => "GITLAB_TOKEN"
           } = response["secret"]

    refute inspect(response) =~ "must-never-be-returned"
    assert response["secrets"] == [response["secret"]]

    attachment =
      KnowledgeBlockSecret
      |> Ash.Query.filter(id == ^attachment_id)
      |> Ash.Query.load(:secret)
      |> Ash.read_one!(authorize?: false)

    secret_id = attachment.secret_id
    assert {:ok, "must-never-be-returned"} = Crypto.decrypt(attachment.secret.encrypted_value)

    updated =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> patch("/api/bff/knowledge-blocks/#{block.id}/secrets/#{attachment_id}", %{
        "name" => "Rotated GitLab token",
        "description" => "Updated description",
        "env_name" => "GITLAB_API_TOKEN"
      })
      |> json_response(200)

    assert %{
             "name" => "Rotated GitLab token",
             "description" => "Updated description",
             "env_name" => "GITLAB_API_TOKEN"
           } = updated["secret"]

    unchanged = Ash.get!(Secret, secret_id, authorize?: false)
    assert {:ok, "must-never-be-returned"} = Crypto.decrypt(unchanged.encrypted_value)

    rotated_response =
      conn
      |> recycle()
      |> sign_in_conn(actor.username, password)
      |> patch("/api/bff/knowledge-blocks/#{block.id}/secrets/#{attachment_id}", %{
        "value" => "rotated-never-returned"
      })
      |> json_response(200)

    refute inspect(rotated_response) =~ "rotated-never-returned"

    rotated = Ash.get!(Secret, secret_id, authorize?: false)
    assert {:ok, "rotated-never-returned"} = Crypto.decrypt(rotated.encrypted_value)

    conn
    |> recycle()
    |> sign_in_conn(actor.username, password)
    |> delete("/api/bff/knowledge-blocks/#{block.id}/secrets/#{attachment_id}")
    |> json_response(200)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(Secret, secret_id, authorize?: false)
  end

  test "deleting a parent deletes its attached secret and global secret API is absent", %{
    conn: conn
  } do
    %{user: actor, password: password} = user_fixture()

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "ssh",
          name: "SSH",
          alias: "ssh",
          config: %{"host" => "example.com", "username" => "agent"},
          secrets: %{"password" => "login-password"}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    response =
      conn
      |> sign_in_conn(actor.username, password)
      |> post("/api/bff/tool-instances/#{tool.id}/secrets", %{
        "name" => "Remote API token",
        "description" => "Remote API access",
        "env_name" => "REMOTE_API_TOKEN",
        "value" => "owned-by-tool"
      })
      |> json_response(200)

    attachment_id = response["secret"]["id"]

    attachment =
      ToolInstanceSecret
      |> Ash.Query.filter(id == ^attachment_id)
      |> Ash.read_one!(authorize?: false)

    secret_id = attachment.secret_id

    tool
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
    |> Ash.destroy!(actor: actor)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(Secret, secret_id, authorize?: false)

    conn
    |> recycle()
    |> sign_in_conn(actor.username, password)
    |> get("/api/ash/secrets")
    |> response(404)
  end
end
