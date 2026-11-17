defmodule IntellectualClub.Tools.Drivers.Lua do
  @moduledoc "Small Lua tools with explicit exports, scoped JSON state and HTTP capabilities."
  @behaviour IntellectualClub.Tools.Driver

  alias IntellectualClub.Accounts.User
  alias IntellectualClub.Secrets.Resolver
  alias IntellectualClub.Tools.{ExecutionContext, LuaState, ToolInstance}
  alias IntellectualClub.Tools.Lua.{Admission, Config, Runtime}

  @impl true
  def type, do: "lua"
  @impl true
  def title, do: "Lua"
  @impl true
  def description,
    do: "Run small Lua tools with per-chat-family state and explicitly allowed HTTP access."

  @impl true
  def functions_mode, do: :fixed
  @impl true
  def supports_discovery?, do: false
  @impl true
  def supports_artifacts?, do: false
  @impl true
  def interruptible?, do: false
  @impl true
  def default_config, do: Config.default()
  @impl true
  def secrets_schema, do: nil
  @impl true
  def config_schema do
    %{
      "type" => "object",
      "properties" => %{"source" => %{"type" => "string"}, "manifest" => %{"type" => "object"}},
      "required" => ["source", "manifest"],
      "additionalProperties" => false
    }
  end

  @impl true
  def validate_config(_tool, config, actor) do
    with :ok <- Config.validate(config),
         do: Runtime.validate_source(config["source"], actor && Map.get(actor, :id))
  end

  @impl true
  def fixed_functions(%ToolInstance{config: config}) do
    case Config.validate(config) do
      :ok -> Config.functions(config)
      _ -> []
    end
  end

  @impl true
  def discover(_tool), do: {:error, "Lua tools use a static manifest, not discovery."}

  @impl true
  def execute(tool, name, args, context \\ nil)

  def execute(%ToolInstance{} = tool, name, args, %ExecutionContext{} = context)
      when is_map(args) do
    Admission.with_slot(context.owner_id, fn -> execute_current(tool, name, args, context) end)
  end

  def execute(_tool, _name, _args, _context),
    do:
      {:error,
       "Lua tools require JSON object arguments and an authenticated chat execution context."}

  defp execute_current(tool, name, args, context) do
    with {:ok, tool} <- current_tool(tool, context),
         :ok <- Config.validate(tool.config),
         {:ok, function} <- exported_function(tool.config, name),
         :ok <- Runtime.validate_arguments(args, function["schema"], context.owner_id),
         {:ok, secrets} <-
           Resolver.resolve_tool_selected(tool, Config.secret_names(tool.config), context) do
      LuaState.with_state(tool, context, fn state ->
        Runtime.execute(
          tool.config["source"],
          name,
          args,
          state,
          Config.permissions(tool.config),
          secrets,
          context.owner_id
        )
        |> case do
          {:error, message} when is_binary(message) -> {:error, {:lua_error, message}}
          result -> result
        end
      end)
      |> case do
        {:ok, value} ->
          {:ok, {Jason.encode!(value), value}}

        {:error, message} ->
          {:error,
           "#{message} State was not saved. External HTTP effects, if any, are not rolled back; do not retry blindly."}
      end
    end
  end

  defp current_tool(%ToolInstance{id: id}, %ExecutionContext{owner_id: owner_id})
       when is_integer(id) and is_integer(owner_id) and owner_id > 0 do
    case Ash.get(ToolInstance, id, actor: %User{id: owner_id}, authorize?: true) do
      {:ok, %ToolInstance{type: "lua"} = tool} -> {:ok, tool}
      _ -> {:error, "Lua tool is not accessible in this execution context."}
    end
  end

  defp current_tool(_tool, _context),
    do: {:error, "Lua tools require an authenticated execution context."}

  defp exported_function(config, name) do
    case Enum.find(Config.functions(config), &(&1["name"] == name)) do
      nil -> {:error, "Unknown or unexported Lua function."}
      function -> {:ok, function}
    end
  end
end
