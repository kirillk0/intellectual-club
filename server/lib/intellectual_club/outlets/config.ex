defmodule IntellectualClub.Outlets.Config do
  @moduledoc """
  Outlet tool instance runtime configuration.

  Values are stored in `tool_instance.config` (a map) and clamped to safe bounds.
  """

  @enforce_keys [
    :max_concurrency,
    :poll_max_wait_seconds,
    :runner_online_timeout_seconds,
    :disconnect_grace_seconds
  ]

  defstruct [
    :max_concurrency,
    :poll_max_wait_seconds,
    :runner_online_timeout_seconds,
    :disconnect_grace_seconds
  ]

  @type t :: %__MODULE__{
          max_concurrency: pos_integer(),
          poll_max_wait_seconds: float(),
          runner_online_timeout_seconds: float(),
          disconnect_grace_seconds: float()
        }

  @spec from_tool_instance(map()) :: t()
  def from_tool_instance(tool_instance) when is_map(tool_instance) do
    cfg = Map.get(tool_instance, :config) || %{}
    cfg = if is_map(cfg), do: cfg, else: %{}

    max_concurrency =
      cfg
      |> read_int("max_concurrency", 20)
      |> clamp_int(1, 1000)

    poll_max_wait_seconds =
      cfg
      |> read_float("poll_max_wait_seconds", 25.0)
      |> clamp_float(1.0, 300.0)

    runner_online_timeout_seconds =
      cfg
      |> read_float("runner_online_timeout_seconds", 60.0)
      |> clamp_float(5.0, 3600.0)

    disconnect_grace_seconds =
      cfg
      |> read_float("disconnect_grace_seconds", 300.0)
      |> clamp_float(0.0, 86_400.0)

    %__MODULE__{
      max_concurrency: max_concurrency,
      poll_max_wait_seconds: poll_max_wait_seconds,
      runner_online_timeout_seconds: runner_online_timeout_seconds,
      disconnect_grace_seconds: disconnect_grace_seconds
    }
  end

  defp read_int(%{} = cfg, key, default) when is_binary(key) and is_integer(default) do
    raw = Map.get(cfg, key) || Map.get(cfg, String.to_existing_atom(key), nil)

    cond do
      is_integer(raw) -> raw
      is_float(raw) -> trunc(raw)
      is_binary(raw) -> parse_int(raw, default)
      true -> default
    end
  rescue
    ArgumentError -> default
  end

  defp read_float(%{} = cfg, key, default) when is_binary(key) and is_number(default) do
    raw = Map.get(cfg, key) || Map.get(cfg, String.to_existing_atom(key), nil)

    cond do
      is_float(raw) -> raw
      is_integer(raw) -> raw * 1.0
      is_binary(raw) -> parse_float(raw, default)
      true -> default
    end
  rescue
    ArgumentError -> default
  end

  defp parse_int(value, default) when is_binary(value) and is_integer(default) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end

  defp parse_float(value, default) when is_binary(value) and is_number(default) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> default * 1.0
    end
  end

  defp clamp_int(value, min_value, max_value)
       when is_integer(value) and is_integer(min_value) and is_integer(max_value) do
    value |> max(min_value) |> min(max_value)
  end

  defp clamp_float(value, min_value, max_value)
       when is_number(value) and is_number(min_value) and is_number(max_value) do
    value |> max(min_value) |> min(max_value) |> Kernel.*(1.0)
  end
end
