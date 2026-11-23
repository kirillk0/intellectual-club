defmodule IntellectualClub.Tools.Drivers.NativeKnowledgeLibrary.WriteFunctions do
  @moduledoc false

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Knowledge.LibraryWrites
  alias IntellectualClub.Tools.{ExecutionContext, ToolInstance}
  alias IntellectualClub.Tools.Lua.Schema

  require Ash.Query

  @name_schema %{
    "type" => "string",
    "minLength" => 1,
    "description" => "Nonblank block name; names need not be unique."
  }
  @version_schema %{
    "type" => "string",
    "description" => "User-defined version label, not a revision token."
  }
  @target %{
    "block_id" => %{"type" => "integer", "minimum" => 1, "maximum" => 9_223_372_036_854_775_807},
    "expected_revision" => %{
      "type" => "string",
      "minLength" => 1,
      "description" =>
        "Exact revision from list_blocks, read_block or the last successful write. Reread on conflict."
    }
  }
  @replacement %{
    "type" => "object",
    "properties" => %{
      "old_text" => %{"type" => "string", "minLength" => 1},
      "new_text" => %{"type" => "string"}
    },
    "required" => ["old_text", "new_text"],
    "additionalProperties" => false
  }
  @definitions [
    {"create_block",
     "Create a new block in the library root tag, even if its name already exists.",
     %{
       "name" => @name_schema,
       "version" => @version_schema,
       "content" => %{
         "type" => "string",
         "description" => "Complete Markdown content for the new block."
       }
     }, ~w(name content)},
    {"edit_block",
     "Edit a block in place everywhere it is used. Supply at least one change. All changes succeed together or none are saved.",
     Map.merge(@target, %{
       "name" => @name_schema,
       "version" => @version_schema,
       "replacements" => %{
         "type" => "array",
         "items" => @replacement,
         "description" =>
           "Ordered literal replacements, each with exactly one visible match. Copy old_text from read_block with view=edit. Use an empty new_text to remove a fragment."
       },
       "append_text" => %{
         "type" => "string",
         "description" =>
           "Append this exact text after applying all replacements. Include any needed newline."
       }
     }), ~w(block_id expected_revision)},
    {"delete_block",
     "Permanently delete the block itself, not just its library tag. A block with outside tags, references, shares or attachments cannot be deleted here.",
     @target, ~w(block_id expected_revision)}
  ]
  @specs Enum.map(@definitions, fn {name, description, properties, required} ->
           %{
             "name" => name,
             "description" => description,
             "enabled" => false,
             "enabled_by_default" => false,
             "schema" => %{
               "type" => "object",
               "properties" => properties,
               "required" => required,
               "additionalProperties" => false
             }
           }
         end)
  @schemas Map.new(@specs, &{&1["name"], &1["schema"]})

  def specs, do: @specs
  def names, do: Map.keys(@schemas)

  def run(%ToolInstance{id: tool_id, owner_id: id}, name, args, %ExecutionContext{owner_id: id})
      when is_integer(id) and id > 0 do
    actor = %User{id: id}

    with {:ok, tag_id} <- enabled_tag(tool_id, actor, name),
         :ok <- validate(name, args) do
      case name do
        "create_block" ->
          LibraryWrites.create(tag_id, actor, args)

        "edit_block" ->
          LibraryWrites.edit(
            tag_id,
            actor,
            trunc(args["block_id"]),
            args["expected_revision"],
            Map.drop(args, ~w(block_id expected_revision))
          )

        "delete_block" ->
          LibraryWrites.delete(tag_id, actor, trunc(args["block_id"]), args["expected_revision"])
      end
    end
  end

  def run(_tool, _name, _args, _context),
    do: {:error, :forbidden, "Only the library tool owner can write in an authenticated chat."}

  # A resolved chat binding can outlive a configuration change. Never mutate
  # through a stale tag, or rely only on the provider's list of enabled tools.
  defp enabled_tag(tool_id, actor, name) do
    ToolInstance
    |> Ash.Query.filter(
      id == ^tool_id and owner_id == ^actor.id and type == "native-knowledge-library" and
        exists(functions, name == ^name and enabled == true)
    )
    |> Ash.Query.select([:config])
    |> Ash.read_one(actor: actor, authorize?: true)
    |> case do
      {:ok, %ToolInstance{config: %{"knowledge_tag_id" => tag_id}}}
      when is_integer(tag_id) and tag_id > 0 ->
        {:ok, tag_id}

      {:ok, %ToolInstance{}} ->
        {:error, :tag_not_available, "Configure a knowledge tag before writing."}

      _ ->
        {:error, :tool_function_disabled, "This library write function is not enabled."}
    end
  end

  defp validate(name, args) do
    case Schema.validate(args, Map.fetch!(@schemas, name)) do
      :ok ->
        cond do
          Map.has_key?(args, "name") and String.trim(args["name"]) == "" ->
            {:error, :invalid_arguments, "Block name must not be blank."}

          name == "edit_block" and
              not (Map.has_key?(args, "name") or Map.has_key?(args, "version") or
                     Map.get(args, "replacements", []) != [] or
                       Map.get(args, "append_text", "") != "") ->
            {:error, :invalid_arguments, "Supply a name, version, replacement or text to append."}

          true ->
            :ok
        end

      {:error, message} ->
        {:error, :invalid_arguments, message}
    end
  end
end
