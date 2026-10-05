defmodule IntellectualClubWeb.AshJsonApiContract do
  @moduledoc """
  Shared contracts for resources exposed through the AshJsonApi endpoints
  (`/api/ash/...`): signed-in requests, duplication, deletion, the image file
  lifecycle, credential status attributes and bindings managed through the
  parent update action.

  Import it next to `IntellectualClubWeb.ConnCase`. Signed-in helpers take the
  `%{user: user, password: password}` map returned by `user_fixture/1`.
  """

  import ExUnit.Assertions
  import IntellectualClub.AccountsFixtures, only: [sign_in_conn: 2]
  import IntellectualClub.ImageFixtures, only: [png_1x1: 0]
  import IntellectualClubWeb.JsonApiHelpers

  alias IntellectualClub.Files
  alias IntellectualClub.Files.File, as: StoredFile
  alias IntellectualClub.Files.{FilesystemStorage, GarbageCollector}

  @doc "Builds a fresh connection signed in as the `user_fixture/1` result."
  def signed_in(%{user: _user, password: _password} = fixture) do
    sign_in_conn(Phoenix.ConnTest.build_conn(), fixture)
  end

  @doc "Sends a signed-in JSON:API `GET` and returns the decoded body for `status`."
  def api_get!(fixture, path, status \\ 200) do
    fixture |> signed_in() |> json_api_get(path) |> Phoenix.ConnTest.json_response(status)
  end

  @doc "Sends a signed-in JSON:API `GET` and returns the primary record attributes."
  def api_attributes!(fixture, path) do
    fixture |> api_get!(path) |> get_in(["data", "attributes"])
  end

  @doc "Sends a signed-in JSON:API `PATCH` of `attributes` to `path` and returns the conn."
  def api_patch(fixture, path, type, id, attributes) do
    document = %{"data" => %{"type" => type, "id" => to_string(id), "attributes" => attributes}}
    fixture |> signed_in() |> json_api_patch(path, document)
  end

  @doc "Sends a signed-in JSON:API `POST` creating `type` with `attributes`; returns the conn."
  def api_create(fixture, path, type, attributes) do
    fixture |> signed_in() |> json_api_post(path, json_api_data(type, attributes))
  end

  @doc "Returns the integer id of the primary record of a JSON:API response."
  def response_id(%{"data" => %{"id" => id}}), do: String.to_integer(to_string(id))

  @doc "Returns the error `detail` strings of a JSON:API error response."
  def error_details(%{"errors" => errors}) when is_list(errors),
    do: Enum.map(errors, &Map.get(&1, "detail", ""))

  @doc """
  Asserts that the request was rejected as invalid (400 or 422) and returns
  the error details.
  """
  def assert_invalid!(%Plug.Conn{} = conn) do
    assert conn.status in [400, 422], inspect(conn.resp_body)
    conn |> Phoenix.ConnTest.json_response(conn.status) |> error_details()
  end

  @doc """
  Calls `POST <collection>/:id/duplicate` and returns `{duplicated_id, response}`.
  """
  def duplicate!(fixture, collection, type, source_id) do
    response =
      fixture
      |> signed_in()
      |> json_api_post("#{collection}/#{source_id}/duplicate", json_api_data(type, %{}))
      |> Phoenix.ConnTest.json_response(201)

    {response_id(response), response}
  end

  @doc "Calls `DELETE path` and asserts a successful (200/204) response."
  def delete!(fixture, path) do
    conn = fixture |> signed_in() |> json_api_delete(path)
    assert conn.status in [200, 204], inspect(conn.resp_body)
    conn
  end

  @doc "Asserts that `resource` has no record `id` visible with `opts`."
  def assert_not_found(resource, id, opts) do
    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(resource, id, opts)
  end

  @doc "Stores a 1x1 PNG through `Files.create_from_upload/1`."
  def create_image_file!(filename) do
    assert {:ok, file} =
             Files.create_from_upload(%{
               filename: filename,
               mime_type: "image/png",
               payload: png_1x1()
             })

    file
  end

  @doc """
  Asserts that `copy_file_id` is a new file row with the payload and name of
  `source_file`.
  """
  def assert_image_file_copied(source_file, copy_file_id) do
    assert is_integer(copy_file_id)
    assert copy_file_id != source_file.id
    copy = Ash.get!(StoredFile, copy_file_id, authorize?: false)
    assert copy.sha256 == source_file.sha256
    assert copy.filename == source_file.filename
  end

  @doc """
  Asserts that `file` row is gone and its payload is released for garbage
  collection.
  """
  def assert_image_file_purged(file) do
    assert_not_found(StoredFile, file.id, authorize?: false)
    assert {:ok, :deleted} = GarbageCollector.collect_sha256(file.sha256)
    refute FilesystemStorage.exists?(file.sha256)
  end

  @doc """
  Generates the image file lifecycle contract for a resource with an
  `:attach_image_file` action: duplication copies the file row and deleting
  the record purges its file.

  Options: `:resource`, `:collection` (`"/api/ash/bots"`), `:type` (`"bots"`)
  and `:create` (a function `actor -> record`).
  """
  defmacro image_file_lifecycle_contract(opts) do
    resource = Keyword.fetch!(opts, :resource)
    collection = Keyword.fetch!(opts, :collection)
    type = Keyword.fetch!(opts, :type)
    create = Keyword.fetch!(opts, :create)

    quote do
      test "POST /:id/duplicate creates a new image file row with the same payload" do
        %{user: actor} = owner = user_fixture()
        source_file = create_image_file!("source.png")
        source = attach_image!(unquote(create).(actor), source_file, actor)

        {copy_id, _response} = duplicate!(owner, unquote(collection), unquote(type), source.id)

        copy = Ash.get!(unquote(resource), copy_id, actor: actor)
        assert_image_file_copied(source_file, copy.image_file_id)
      end

      test "DELETE /:id purges the image payload but keeps payloads sharing its directory" do
        %{user: actor} = owner = user_fixture()
        file = create_image_file!("deleted.png")
        record = attach_image!(unquote(create).(actor), file, actor)

        sibling = create_shard_sibling!(file.sha256)

        delete!(owner, "#{unquote(collection)}/#{record.id}")

        assert_image_file_purged(file)
        assert FilesystemStorage.exists?(sibling.sha256)
      end
    end
  end

  @doc """
  Stores a text payload whose SHA-256 shares the first directory level with
  `sha256`, so pruning the directories of `sha256` meets a non-empty directory.
  """
  def create_shard_sibling!(sha256) do
    prefix = binary_part(sha256, 0, 2)

    payload =
      Stream.iterate(0, &(&1 + 1))
      |> Stream.map(&"shard sibling #{&1}")
      |> Enum.find(fn payload ->
        hash = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
        String.starts_with?(hash, prefix) and hash != sha256
      end)

    assert {:ok, file} = Files.create_from_binary("sibling.txt", "text/plain", payload)
    file
  end

  @doc "Attaches a stored image `file` to `record` through `:attach_image_file`."
  def attach_image!(record, file, actor) do
    record
    |> Ash.Changeset.for_update(:attach_image_file, %{image_file_id: file.id}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  @doc """
  Asserts that a has-many binding relationship is fully managed through the
  parent update action: setting a list creates the bindings, a list that keeps
  one binding by `"id"` removes the others while keeping that row, an empty
  list removes all bindings, and the parent `GET` reflects every state through
  relationships and `included`.

  `spec` keys:
    * `:collection`, `:type`, `:id` - the parent record;
    * `:include` - the include query used for every request;
    * `:relationships` - a list of maps with `:name` (relationship),
      `:resource` (binding resource), `:parent_key`, `:target_key`,
      `:included` (target JSON:API type), `:targets` (at least two target ids),
      `:attrs` (`fn target_id, index -> binding attributes end`) and optional
      `:load`, `:project` (`fn binding -> value end`, default: target id),
      `:expect_set` / `:expect_keep` (projected values), `:keep_changes`
      (attributes merged into the kept binding);
    * `:static` - optional `[{relationship, included_type, id}]` that must be
      unchanged by binding updates.
  """
  def assert_manages_bindings(fixture, spec) do
    %{user: actor} = fixture
    rels = spec.relationships
    path = "#{spec.collection}/#{spec.id}?include=#{spec.include}"

    set_payload =
      Map.new(rels, fn rel ->
        {rel.name,
         rel.targets |> Enum.with_index() |> Enum.map(fn {t, i} -> rel.attrs.(t, i) end)}
      end)

    set_response = patch_bindings!(fixture, spec, path, set_payload)

    set_bindings =
      Map.new(rels, fn rel ->
        bindings = read_bindings(rel, spec.id, actor)

        assert_binding_state(set_response, rel, bindings, rel.targets, Map.get(rel, :expect_set))

        {rel.name, bindings}
      end)

    kept =
      Map.new(rels, fn rel ->
        [first_target | _rest] = rel.targets

        {rel.name,
         Enum.find(set_bindings[rel.name], &(Map.fetch!(&1, rel.target_key) == first_target))}
      end)

    keep_payload =
      Map.new(rels, fn rel ->
        attrs =
          rel.attrs.(hd(rel.targets), 0)
          |> Map.merge(Map.get(rel, :keep_changes, %{}))
          |> Map.put("id", kept[rel.name].id)

        {rel.name, [attrs]}
      end)

    keep_response = patch_bindings!(fixture, spec, path, keep_payload)
    get_response = api_get!(fixture, path)

    for rel <- rels do
      bindings = read_bindings(rel, spec.id, actor)
      assert Enum.map(bindings, & &1.id) == [kept[rel.name].id]

      for response <- [keep_response, get_response] do
        assert_binding_state(
          response,
          rel,
          bindings,
          [hd(rel.targets)],
          Map.get(rel, :expect_keep)
        )
      end
    end

    clear_response = patch_bindings!(fixture, spec, path, Map.new(rels, &{&1.name, []}))

    for rel <- rels do
      assert read_bindings(rel, spec.id, actor) == []
      assert_binding_state(clear_response, rel, [], [], [])
    end

    assert_static_relationships(api_get!(fixture, path), spec)
  end

  defp patch_bindings!(fixture, spec, path, payload) do
    response =
      fixture
      |> api_patch(path, spec.type, spec.id, payload)
      |> Phoenix.ConnTest.json_response(200)

    assert_static_relationships(response, spec)
    response
  end

  defp assert_static_relationships(response, spec) do
    for {relationship, included_type, id} <- Map.get(spec, :static, []) do
      assert relationship_ids(response, relationship) == [id]
      assert ids_from_included(response, included_type) == [id]
    end
  end

  defp assert_binding_state(response, rel, bindings, targets, expected) do
    project = Map.get(rel, :project, &Map.fetch!(&1, rel.target_key))
    expected = expected || Enum.sort(targets)

    assert bindings |> Enum.map(project) |> Enum.sort() == Enum.sort(expected)
    assert relationship_ids(response, rel.name) == bindings |> Enum.map(& &1.id) |> Enum.sort()
    assert ids_from_included(response, rel.included) == Enum.sort(targets)
  end

  defp read_bindings(rel, parent_id, actor) do
    rel.resource
    |> Ash.Query.do_filter([{rel.parent_key, parent_id}])
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.load(Map.get(rel, :load, []))
    |> Ash.read!(actor: actor)
  end
end
