defmodule IntellectualClub.SecretsTest do
  use IntellectualClub.DataCase, async: true

  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Knowledge.PromptContent

  alias IntellectualClub.Secrets.{
    Crypto,
    KnowledgeBlockSecret,
    Resolver,
    Secret,
    ToolInstanceSecret
  }

  alias IntellectualClub.Tools.{ExecutionContext, ToolInstance}

  require Ash.Query

  test "stores authenticated ciphertext and never renders the value in prompt metadata" do
    %{user: actor} = user_fixture()

    secret = create_secret!(actor, "GitLab token", "gitlab-secret-value")

    refute secret.encrypted_value == "gitlab-secret-value"
    refute String.contains?(secret.encrypted_value, "gitlab-secret-value")
    assert {:ok, "gitlab-secret-value"} = Crypto.decrypt(secret.encrypted_value)

    <<head, rest::binary>> = secret.encrypted_value

    tampered =
      <<head, Bitwise.bxor(:binary.at(rest, 0), 1),
        binary_part(rest, 1, byte_size(rest) - 1)::binary>>

    assert {:error, :invalid_ciphertext} = Crypto.decrypt(tampered)

    rendered =
      PromptContent.render_block(%{
        name: "GitLab access",
        content: "Use the API.",
        file_bindings: [],
        secret_bindings: [
          %{
            id: 1,
            env_name: "GITLAB_TOKEN",
            enabled: true,
            sequence: 0,
            secret: %{name: secret.name, description: secret.description}
          }
        ]
      })

    assert rendered =~ "`GITLAB_TOKEN`"
    assert rendered =~ "GitLab API credential"
    refute rendered =~ "gitlab-secret-value"
  end

  test "resolves only secrets bound to the current tool or current prompt blocks" do
    %{user: actor} = user_fixture()
    tool_secret = create_secret!(actor, "Tool token", "tool-value")
    block_secret = create_secret!(actor, "Block token", "block-value")

    tool =
      ToolInstance
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: "outlet",
          name: "Shell outlet",
          alias: "shell",
          config: %{},
          secrets: %{"token" => "runner-token"}
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    tool_binding =
      ToolInstanceSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          tool_instance_id: tool.id,
          secret_id: tool_secret.id,
          env_name: "TOOL_TOKEN"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(
        :create,
        %{name: "API access", content: "Use the API."},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    block_binding =
      KnowledgeBlockSecret
      |> Ash.Changeset.for_create(
        :create,
        %{
          knowledge_block_id: block.id,
          secret_id: block_secret.id,
          env_name: "BLOCK_TOKEN"
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    assert {:error, reuse_error} =
             KnowledgeBlockSecret
             |> Ash.Changeset.for_create(
               :create,
               %{
                 knowledge_block_id: block.id,
                 secret_id: tool_secret.id,
                 env_name: "REUSED_TOKEN"
               },
               actor: actor
             )
             |> Ash.create(actor: actor)

    assert Exception.message(reuse_error) =~ "is already attached to another resource"

    context = %ExecutionContext{
      owner_id: actor.id,
      available_secret_binding_external_ids: [block_binding.external_id]
    }

    assert {:ok, %{"TOOL_TOKEN" => "tool-value", "BLOCK_TOKEN" => "block-value"}} =
             Resolver.resolve_selected(tool, ["TOOL_TOKEN", "BLOCK_TOKEN"], context)

    context_without_block = %{context | available_secret_binding_external_ids: []}

    assert {:error, "Secret `BLOCK_TOKEN` is not available to this tool call."} =
             Resolver.resolve_selected(tool, ["BLOCK_TOKEN"], context_without_block)

    assert {:error, "Secret `token` is not available to this tool call."} =
             Resolver.resolve_selected(tool, ["token"], context)

    tool_binding
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
    |> Ash.destroy!(actor: actor)

    assert {:error, "Secret `TOOL_TOKEN` is not available to this tool call."} =
             Resolver.resolve_selected(tool, ["TOOL_TOKEN"], context)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(Secret, tool_secret.id, authorize?: false)
  end

  test "duplicating a resource duplicates its secret instead of sharing it" do
    %{user: actor} = user_fixture()
    secret = create_secret!(actor, "Source token", "source-value")

    block =
      KnowledgeBlock
      |> Ash.Changeset.for_create(:create, %{name: "Source block", content: "Use API."},
        actor: actor
      )
      |> Ash.create!(actor: actor)

    KnowledgeBlockSecret
    |> Ash.Changeset.for_create(
      :create,
      %{knowledge_block_id: block.id, secret_id: secret.id, env_name: "SOURCE_TOKEN"},
      actor: actor
    )
    |> Ash.create!(actor: actor)

    duplicated =
      KnowledgeBlock
      |> Ash.Changeset.for_create(:duplicate, %{id: block.id}, actor: actor)
      |> Ash.create!(actor: actor)

    duplicated_binding =
      KnowledgeBlockSecret
      |> Ash.Query.filter(knowledge_block_id == ^duplicated.id)
      |> Ash.Query.load(:secret)
      |> Ash.read_one!(actor: actor)

    refute duplicated_binding.secret_id == secret.id
    assert {:ok, "source-value"} = Crypto.decrypt(duplicated_binding.secret.encrypted_value)

    duplicated_secret_id = duplicated_binding.secret_id

    duplicated
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
    |> Ash.destroy!(actor: actor)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(Secret, duplicated_secret_id, authorize?: false)

    assert %Secret{id: source_secret_id} = Ash.get!(Secret, secret.id, actor: actor)
    assert source_secret_id == secret.id
  end

  defp create_secret!(actor, name, value) do
    Secret
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, description: "GitLab API credential", value: value},
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
