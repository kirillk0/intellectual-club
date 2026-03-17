defmodule IntellectualClub.Tools.Driver do
  @moduledoc """
  Tool driver behaviour.

  Drivers implement network I/O (discovery + execution) for a specific tool type.
  """

  @type tool_type :: String.t()
  @type functions_mode :: :fixed | :stored

  @callback type() :: tool_type()
  @callback title() :: String.t()
  @callback description() :: String.t()

  @callback functions_mode() :: functions_mode()
  @callback supports_discovery?() :: boolean()

  @callback config_schema() :: map()
  @callback secrets_schema() :: map() | nil
  @callback default_config() :: map()
  @callback fixed_functions(IntellectualClub.Tools.ToolInstance.t()) :: list(map())

  @callback discover(IntellectualClub.Tools.ToolInstance.t()) ::
              {:ok, list(map())} | {:error, term()}

  @callback execute(
              IntellectualClub.Tools.ToolInstance.t(),
              String.t(),
              map(),
              IntellectualClub.Tools.ExecutionContext.t() | nil
            ) ::
              {:ok, IntellectualClub.Tools.ExecutionResult.t() | {String.t(), map()} | map()}
              | {:error, term()}

  @optional_callbacks fixed_functions: 1
end
