defmodule IntellectualClubWeb.Bff.ManagedSecretsController do
  @moduledoc """
  Parent-scoped CRUD for managed-secret attachments.
  """

  use IntellectualClubWeb, :controller

  alias IntellectualClub.Knowledge.KnowledgeBlock
  alias IntellectualClub.Repo
  alias IntellectualClub.Secrets.{KnowledgeBlockSecret, Secret, ToolInstanceSecret}
  alias IntellectualClub.Tools.ToolInstance
  alias IntellectualClubWeb.Bff.Helpers

  require Ash.Query

  def knowledge_index(conn, %{"id" => id}), do: index(conn, :knowledge_block, id)
  def tool_index(conn, %{"id" => id}), do: index(conn, :tool_instance, id)

  def knowledge_create(conn, %{"id" => id} = params),
    do: create(conn, :knowledge_block, id, params)

  def tool_create(conn, %{"id" => id} = params),
    do: create(conn, :tool_instance, id, params)

  def knowledge_update(conn, %{"id" => id, "secret_id" => attachment_id} = params),
    do: update(conn, :knowledge_block, id, attachment_id, params)

  def tool_update(conn, %{"id" => id, "secret_id" => attachment_id} = params),
    do: update(conn, :tool_instance, id, attachment_id, params)

  def knowledge_delete(conn, %{"id" => id, "secret_id" => attachment_id}),
    do: delete(conn, :knowledge_block, id, attachment_id)

  def tool_delete(conn, %{"id" => id, "secret_id" => attachment_id}),
    do: delete(conn, :tool_instance, id, attachment_id)

  defp index(conn, kind, raw_parent_id) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         parent_id when is_integer(parent_id) <- Helpers.parse_optional_integer(raw_parent_id),
         {:ok, _parent} <- get_parent(kind, parent_id, actor),
         {:ok, attachments} <- list_attachments(kind, parent_id, actor) do
      json(conn, %{secrets: Enum.map(attachments, &serialize_attachment/1)})
    else
      {:error, %Plug.Conn{} = conn} -> conn
      _other -> render_not_found(conn)
    end
  end

  defp create(conn, kind, raw_parent_id, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         parent_id when is_integer(parent_id) <- Helpers.parse_optional_integer(raw_parent_id),
         {:ok, parent} <- get_parent(kind, parent_id, actor),
         :ok <- require_owner(parent, actor),
         {:ok, attrs} <- create_attrs(params),
         {:ok, attachment} <- create_attachment(kind, parent_id, attrs, actor),
         {:ok, attachments} <- list_attachments(kind, parent_id, actor) do
      json(conn, %{
        secret: serialize_attachment(attachment),
        secrets: Enum.map(attachments, &serialize_attachment/1)
      })
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, :forbidden} -> render_forbidden(conn)
      {:error, message} when is_binary(message) -> render_validation_error(conn, message)
      {:error, error} -> render_action_error(conn, error)
      _other -> render_not_found(conn)
    end
  end

  defp update(conn, kind, raw_parent_id, raw_attachment_id, params) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         parent_id when is_integer(parent_id) <- Helpers.parse_optional_integer(raw_parent_id),
         attachment_id when is_integer(attachment_id) <-
           Helpers.parse_optional_integer(raw_attachment_id),
         {:ok, parent} <- get_parent(kind, parent_id, actor),
         :ok <- require_owner(parent, actor),
         {:ok, attachment} <- get_attachment(kind, parent_id, attachment_id, actor),
         {:ok, {attachment_attrs, secret_attrs}} <- update_attrs(params),
         {:ok, attachment} <-
           update_attachment(attachment, attachment_attrs, secret_attrs, actor),
         {:ok, attachments} <- list_attachments(kind, parent_id, actor) do
      json(conn, %{
        secret: serialize_attachment(attachment),
        secrets: Enum.map(attachments, &serialize_attachment/1)
      })
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, :forbidden} -> render_forbidden(conn)
      {:error, message} when is_binary(message) -> render_validation_error(conn, message)
      {:error, error} -> render_action_error(conn, error)
      _other -> render_not_found(conn)
    end
  end

  defp delete(conn, kind, raw_parent_id, raw_attachment_id) do
    with {:ok, actor} <- Helpers.require_actor(conn),
         parent_id when is_integer(parent_id) <- Helpers.parse_optional_integer(raw_parent_id),
         attachment_id when is_integer(attachment_id) <-
           Helpers.parse_optional_integer(raw_attachment_id),
         {:ok, parent} <- get_parent(kind, parent_id, actor),
         :ok <- require_owner(parent, actor),
         {:ok, attachment} <- get_attachment(kind, parent_id, attachment_id, actor),
         :ok <- destroy_attachment(attachment, actor),
         {:ok, attachments} <- list_attachments(kind, parent_id, actor) do
      json(conn, %{secrets: Enum.map(attachments, &serialize_attachment/1)})
    else
      {:error, %Plug.Conn{} = conn} -> conn
      {:error, :forbidden} -> render_forbidden(conn)
      {:error, error} -> render_action_error(conn, error)
      _other -> render_not_found(conn)
    end
  end

  defp get_parent(:knowledge_block, id, actor), do: Ash.get(KnowledgeBlock, id, actor: actor)

  defp get_parent(:tool_instance, id, actor) do
    case Ash.get(ToolInstance, id, actor: actor) do
      {:ok, %ToolInstance{type: type} = tool} when type in ["ssh", "outlet"] ->
        {:ok, tool}

      {:ok, %ToolInstance{}} ->
        {:error, "Managed secrets are supported only by SSH and outlet tools."}

      other ->
        other
    end
  end

  defp require_owner(%{owner_id: owner_id}, %{id: actor_id})
       when is_integer(owner_id) and owner_id == actor_id,
       do: :ok

  defp require_owner(_parent, _actor), do: {:error, :forbidden}

  defp attachment_resource(:knowledge_block), do: KnowledgeBlockSecret
  defp attachment_resource(:tool_instance), do: ToolInstanceSecret
  defp parent_field(:knowledge_block), do: :knowledge_block_id
  defp parent_field(:tool_instance), do: :tool_instance_id

  defp list_attachments(kind, parent_id, actor) do
    kind
    |> attachment_resource()
    |> filter_parent(kind, parent_id)
    |> Ash.Query.sort(sequence: :asc, id: :asc)
    |> Ash.Query.load([secret: [:id, :external_id, :name, :description]], strict?: true)
    |> Ash.read(actor: actor)
  end

  defp get_attachment(kind, parent_id, attachment_id, actor) do
    kind
    |> attachment_resource()
    |> filter_parent(kind, parent_id)
    |> Ash.Query.filter(id == ^attachment_id)
    |> Ash.Query.load([secret: [:id, :external_id, :name, :description]], strict?: true)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  defp filter_parent(query, :knowledge_block, parent_id),
    do: Ash.Query.filter(query, knowledge_block_id == ^parent_id)

  defp filter_parent(query, :tool_instance, parent_id),
    do: Ash.Query.filter(query, tool_instance_id == ^parent_id and kind == :environment)

  defp create_attachment(kind, parent_id, attrs, actor) do
    resource = attachment_resource(kind)
    field = parent_field(kind)
    sequence = next_sequence(kind, parent_id, actor)

    Ash.transaction([Secret, resource], fn ->
      secret =
        case create_secret(attrs, actor) do
          {:ok, secret} -> secret
          {:error, error} -> Repo.rollback(error)
        end

      attachment_attrs =
        %{
          field => parent_id,
          secret_id: secret.id,
          env_name: attrs.env_name,
          enabled: true,
          sequence: sequence
        }
        |> maybe_put_attachment_kind(kind)

      resource
      |> Ash.Changeset.for_create(
        :create,
        attachment_attrs,
        actor: actor
      )
      |> Ash.create(actor: actor, load: [secret: [:id, :external_id, :name, :description]])
      |> case do
        {:ok, attachment} -> attachment
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp create_secret(attrs, actor) do
    Secret
    |> Ash.Changeset.for_create(
      :create,
      %{name: attrs.name, description: attrs.description, value: attrs.value},
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp update_attachment(attachment, attachment_attrs, secret_attrs, actor) do
    resource = attachment.__struct__

    Ash.transaction([Secret, resource], fn ->
      secret =
        if map_size(secret_attrs) == 0 do
          attachment.secret
        else
          attachment.secret
          |> Ash.Changeset.for_update(:update, secret_attrs, actor: actor)
          |> Ash.update(actor: actor)
          |> case do
            {:ok, secret} -> secret
            {:error, error} -> Repo.rollback(error)
          end
        end

      attachment =
        if map_size(attachment_attrs) == 0 do
          attachment
        else
          attachment
          |> Ash.Changeset.for_update(:update, attachment_attrs, actor: actor)
          |> Ash.update(actor: actor)
          |> case do
            {:ok, attachment} -> attachment
            {:error, error} -> Repo.rollback(error)
          end
        end

      %{attachment | secret: secret}
    end)
  end

  defp next_sequence(kind, parent_id, actor) do
    case list_attachments(kind, parent_id, actor) do
      {:ok, attachments} ->
        Enum.max([-1 | Enum.map(attachments, &(Map.get(&1, :sequence) || 0))]) + 1

      _other ->
        0
    end
  end

  defp destroy_attachment(attachment, actor) do
    attachment
    |> Ash.Changeset.for_destroy(:destroy, %{}, actor: actor)
    |> Ash.destroy(actor: actor)
    |> case do
      :ok -> :ok
      {:ok, _attachment} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp create_attrs(params) do
    with {:ok, name} <- validate_name(Map.get(params, "name")),
         {:ok, env_name} <- validate_env_name(Map.get(params, "env_name")),
         {:ok, description} <- validate_description(Map.get(params, "description", "")),
         {:ok, value} <- validate_create_value(Map.get(params, "value")) do
      {:ok, %{name: name, env_name: env_name, description: description, value: value}}
    end
  end

  defp update_attrs(params) do
    with {:ok, name} <- validate_optional_name(params),
         {:ok, env_name} <- validate_optional_env_name(params),
         {:ok, description} <- validate_optional_description(params),
         {:ok, value} <- validate_optional_value(params) do
      attachment_attrs = maybe_put(%{}, :env_name, env_name)

      secret_attrs =
        %{}
        |> maybe_put(:name, name)
        |> maybe_put(:description, description)
        |> maybe_put(:value, value)

      {:ok, {attachment_attrs, secret_attrs}}
    end
  end

  defp validate_optional_name(%{"name" => value}), do: validate_name(value)
  defp validate_optional_name(_params), do: {:ok, nil}

  defp validate_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "Name is required."}
      name -> {:ok, name}
    end
  end

  defp validate_name(_value), do: {:error, "Name is required."}

  defp validate_optional_env_name(%{"env_name" => value}), do: validate_env_name(value)
  defp validate_optional_env_name(_params), do: {:ok, nil}

  defp validate_env_name(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, value) do
      {:ok, value}
    else
      {:error, "Environment variable name is invalid."}
    end
  end

  defp validate_env_name(_value), do: {:error, "Environment variable name is required."}

  defp validate_optional_description(%{"description" => value}),
    do: validate_description(value)

  defp validate_optional_description(_params), do: {:ok, nil}

  defp validate_description(value) when is_binary(value), do: {:ok, value}
  defp validate_description(_value), do: {:error, "Description must be a string."}

  defp validate_create_value(value) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp validate_create_value(_value), do: {:error, "Value is required."}

  defp validate_optional_value(%{"value" => ""}), do: {:ok, nil}

  defp validate_optional_value(%{"value" => value}) when is_binary(value),
    do: {:ok, value}

  defp validate_optional_value(%{"value" => _value}), do: {:error, "Value must be a string."}
  defp validate_optional_value(_params), do: {:ok, nil}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_attachment_kind(attrs, :tool_instance), do: Map.put(attrs, :kind, :environment)
  defp maybe_put_attachment_kind(attrs, :knowledge_block), do: attrs

  defp serialize_attachment(attachment) do
    secret = Map.get(attachment, :secret)

    %{
      id: attachment.id,
      external_id: attachment.external_id,
      env_name: attachment.env_name,
      name: if(is_map(secret), do: Map.get(secret, :name, ""), else: ""),
      description: if(is_map(secret), do: Map.get(secret, :description, ""), else: "")
    }
  end

  defp render_not_found(conn), do: conn |> put_status(:not_found) |> json(%{error: "Not found."})
  defp render_forbidden(conn), do: conn |> put_status(:forbidden) |> json(%{error: "Forbidden."})

  defp render_validation_error(conn, message),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: message})

  defp render_action_error(conn, error),
    do: render_validation_error(conn, Exception.message(error))
end
