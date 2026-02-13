defmodule Accord.TLA.ModelConfig do
  @moduledoc """
  Loads and resolves model configuration for TLA+ finite domains.

  TLC requires finite sets for model checking, but the protocol DSL uses
  open types like `term()` and `pos_integer()`. The model configuration
  bridges this gap by mapping types and parameter names to bounded domains.

  ## Resolution priority

  1. Per-protocol config (from `use Accord.Protocol, model: "path"`)
  2. Project-wide config (`.accord_model.exs` in project root)
  3. Built-in defaults

  Within each layer, parameter-name overrides take precedence over
  type-level defaults.

  ## Domain values

  - `1..5` — integer range
  - `[:a, :b, :c]` — explicit set
  - `{:model_values, 3}` — TLC generates 3 abstract values with symmetry
  - `{:model_values, [:c1, :c2]}` — named TLC model values with symmetry
  """

  @type domain ::
          Range.t()
          | [term()]
          | {:model_values, pos_integer()}
          | {:model_values, [atom()]}

  @type t :: %__MODULE__{
          domains: %{atom() => domain()},
          symmetry_sets: [atom()],
          max_list_length: pos_integer()
        }

  defstruct domains: %{},
            symmetry_sets: [],
            max_list_length: nil

  @builtin_defaults %{
    pos_integer: 1..3,
    non_neg_integer: 0..3,
    integer: -2..2,
    boolean: [true, false],
    atom: {:model_values, 3},
    term: {:model_values, 3},
    binary: {:model_values, 2},
    string: {:model_values, 2}
  }

  @doc """
  Returns the built-in default domain map.
  """
  @spec builtin_defaults() :: %{atom() => domain()}
  def builtin_defaults, do: @builtin_defaults

  @doc """
  Loads configuration from the given sources and merges them.

  ## Options

  - `:protocol_config_path` — path to per-protocol config file
  - `:project_root` — path to project root (for `.accord_model.exs`)
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    protocol_path = Keyword.get(opts, :protocol_config_path)
    project_root = Keyword.get(opts, :project_root)

    project_config = load_project_config(project_root)
    protocol_config = load_file_config(protocol_path)

    config = merge(protocol_config, project_config)
    %{config | max_list_length: config.max_list_length || 3}
  end

  @doc """
  Resolves a domain for a parameter by name and type.

  Checks in order:
  1. Parameter name in config domains
  2. Type name in config domains
  3. Built-in default for the type
  """
  @spec resolve_domain(t(), atom(), atom()) :: domain()
  def resolve_domain(%__MODULE__{} = config, param_name, type_name) do
    case Map.get(config.domains, param_name) do
      nil ->
        case Map.get(config.domains, type_name) do
          nil -> Map.get(@builtin_defaults, type_name, {:model_values, 3})
          domain -> domain
        end

      domain ->
        domain
    end
  end

  @doc """
  Converts a domain to a TLA+ set expression string.
  """
  @spec domain_to_tla(domain()) :: String.t()
  def domain_to_tla(%Range{first: first, last: last}) do
    "#{first}..#{last}"
  end

  def domain_to_tla(list) when is_list(list) do
    elements =
      Enum.map_join(list, ", ", fn
        atom when is_atom(atom) -> ~s("#{atom}")
        int when is_integer(int) -> Integer.to_string(int)
        str when is_binary(str) -> ~s("#{str}")
        other -> inspect(other)
      end)

    "{#{elements}}"
  end

  def domain_to_tla({:model_values, count}) when is_integer(count) do
    names = Enum.map_join(1..count, ", ", &"mv#{&1}")
    "{#{names}}"
  end

  def domain_to_tla({:model_values, names}) when is_list(names) do
    elements = Enum.map_join(names, ", ", &Atom.to_string/1)
    "{#{elements}}"
  end

  # -- Private --

  defp load_project_config(nil), do: %__MODULE__{}

  defp load_project_config(project_root) do
    path = Path.join(project_root, ".accord_model.exs")
    load_file_config(path)
  end

  defp load_file_config(nil), do: %__MODULE__{}

  defp load_file_config(path) do
    if File.exists?(path) do
      {config, _} = Code.eval_file(path)
      parse_config(config)
    else
      %__MODULE__{}
    end
  end

  defp parse_config(config) when is_list(config) do
    %__MODULE__{
      domains: Keyword.get(config, :domains, %{}),
      symmetry_sets: Keyword.get(config, :symmetry_sets, []),
      max_list_length: Keyword.get(config, :max_list_length, 3)
    }
  end

  defp parse_config(_), do: %__MODULE__{}

  defp merge(protocol, project) do
    %__MODULE__{
      domains: Map.merge(project.domains, protocol.domains),
      symmetry_sets: Enum.uniq(project.symmetry_sets ++ protocol.symmetry_sets),
      max_list_length: protocol.max_list_length || project.max_list_length || 3
    }
  end
end
