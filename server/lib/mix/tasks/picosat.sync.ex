defmodule Mix.Tasks.Picosat.Sync do
  @moduledoc """
  Copies the PicoSAT NIF into the active Mix build path when the dependency
  compiler leaves the build directory without the shared library.
  """

  use Mix.Task

  @shortdoc "Sync the PicoSAT NIF into the current Mix build path"

  @candidate_names [
    "picosat_nif.so",
    "picosat_nif.dylib",
    "picosat_nif.dll"
  ]

  @impl true
  def run(_args) do
    source =
      @candidate_names
      |> Enum.map(&Path.join([File.cwd!(), "deps", "picosat_elixir", "priv", &1]))
      |> Enum.find(&File.exists?/1)

    case source do
      nil ->
        :ok

      source_path ->
        target_dir = Path.join([Mix.Project.build_path(), "lib", "picosat_elixir", "priv"])
        target_path = Path.join(target_dir, Path.basename(source_path))

        if !File.exists?(target_path) do
          File.mkdir_p!(target_dir)
          File.cp!(source_path, target_path)
          Mix.shell().info("Synced #{Path.basename(source_path)} into #{target_dir}")
        end
    end
  end
end
