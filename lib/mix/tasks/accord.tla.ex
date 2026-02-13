defmodule Mix.Tasks.Accord.Tla do
  @moduledoc """
  Prints the generated TLA+ spec for an Accord protocol.

  ## Usage

      mix accord.tla Lock.Protocol              # print the .tla spec
      mix accord.tla Lock.Protocol --cfg        # print the .cfg file instead

  The spec is generated at compile time. If the `.tla` file does not exist,
  this task will compile the project first.
  """

  use Mix.Task

  @shortdoc "Print the generated TLA+ spec for an Accord protocol"

  @impl Mix.Task
  def run(args) do
    {opts, modules, _} = OptionParser.parse(args, strict: [cfg: :boolean])

    case modules do
      [] ->
        Mix.shell().error("Usage: mix accord.tla ModuleName [--cfg]")
        exit({:shutdown, 1})

      [name | _] ->
        Mix.Task.run("compile", [])

        # Safe: developer-provided CLI argument, not untrusted input.
        mod = Module.concat([String.to_atom(name)])
        {tla_path, cfg_path} = tla_paths(mod)
        path = if opts[:cfg], do: cfg_path, else: tla_path

        if File.exists?(path) do
          path |> File.read!() |> Mix.shell().info()
        else
          Mix.shell().error("File not found: #{path}")
          Mix.shell().error("Is #{inspect(mod)} an Accord protocol?")
          exit({:shutdown, 1})
        end
    end
  end

  defp tla_paths(mod) do
    parts = Module.split(mod)
    dir_parts = parts |> Enum.slice(0..-2//1) |> Enum.map(&Macro.underscore/1)

    base_dir = Path.join([Mix.Project.build_path(), "accord" | dir_parts])
    base_name = List.last(parts)

    {
      Path.join(base_dir, "#{base_name}.tla"),
      Path.join(base_dir, "#{base_name}.cfg")
    }
  end
end
