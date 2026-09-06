defmodule IntellectualClub.Tools.Drivers.NativeBraveSearch do
  @moduledoc "Compatibility adapter for legacy instances awaiting the web-search migration."
  @behaviour IntellectualClub.Tools.Driver
  alias IntellectualClub.Tools.Drivers.NativeWebSearch

  def type, do: "native-brave-search"
  defdelegate title(), to: NativeWebSearch
  defdelegate description(), to: NativeWebSearch
  defdelegate functions_mode(), to: NativeWebSearch
  defdelegate supports_discovery?(), to: NativeWebSearch
  defdelegate supports_artifacts?(), to: NativeWebSearch
  defdelegate default_config(), to: NativeWebSearch
  defdelegate config_schema(), to: NativeWebSearch
  defdelegate secrets_schema(), to: NativeWebSearch
  defdelegate normalize_config(config), to: NativeWebSearch
  defdelegate validate_config(tool, config, actor), to: NativeWebSearch
  defdelegate fixed_functions(tool), to: NativeWebSearch
  defdelegate discover(tool), to: NativeWebSearch

  def execute(tool, function, args, context \\ nil),
    do: NativeWebSearch.execute(tool, function, args, context)
end
