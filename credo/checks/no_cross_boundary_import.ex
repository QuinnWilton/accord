defmodule Accord.Checks.NoCrossBoundaryImport do
  @moduledoc """
  Checks that monitor and TLA+ modules do not cross architectural boundaries.

  The runtime pipeline (`Accord.Monitor.*`) and verification pipeline
  (`Accord.Pass.TLA.*`) should only share the IR. Direct imports, aliases,
  or use directives between these boundaries indicate a coupling violation.
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Monitor modules must not depend on TLA+ passes and vice versa.
      The runtime and verification pipelines should only share the IR.
      If you need shared logic, extract it into a module that both
      pipelines can depend on. See the architecture section in CLAUDE.md.
      """
    ]

  @impl true
  def run(%Credo.SourceFile{} = source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    ast = Credo.SourceFile.ast(source_file)
    declaring_module = extract_module_name(ast)

    if relevant_module?(declaring_module) do
      Credo.Code.prewalk(source_file, &traverse(&1, &2, declaring_module, issue_meta))
    else
      []
    end
  end

  # Extract the top-level module name from the AST.
  defp extract_module_name({:defmodule, _, [{:__aliases__, _, aliases} | _]}) do
    Enum.map_join(aliases, ".", &to_string/1)
  end

  defp extract_module_name({:__block__, _, children}) when is_list(children) do
    Enum.find_value(children, &extract_module_name/1)
  end

  defp extract_module_name(_), do: nil

  # Only check files that define monitor or TLA+ modules.
  defp relevant_module?(nil), do: false
  defp relevant_module?(name), do: monitor_module?(name) or tla_module?(name)

  # Check alias, import, and use directives for boundary violations.
  defp traverse(
         {directive, meta, [{:__aliases__, _, target_aliases} | _]} = ast,
         issues,
         declaring_module,
         issue_meta
       )
       when directive in [:alias, :import, :use] do
    target = Enum.map_join(target_aliases, ".", &to_string/1)

    case boundary_violation(declaring_module, target) do
      nil ->
        {ast, issues}

      message ->
        issue = format_issue(issue_meta, message: message, trigger: target, line_no: meta[:line])
        {ast, [issue | issues]}
    end
  end

  defp traverse(ast, issues, _declaring_module, _issue_meta) do
    {ast, issues}
  end

  # Returns a violation message if the dependency crosses boundaries, nil otherwise.
  defp boundary_violation(declaring, target) do
    cond do
      monitor_module?(declaring) and tla_module?(target) ->
        "Monitor modules must not depend on TLA+ passes. " <>
          "The runtime and verification pipelines should only share the IR. " <>
          "See docs/architecture.md."

      tla_module?(declaring) and monitor_module?(target) ->
        "TLA+ pass modules must not depend on monitor modules. " <>
          "The runtime and verification pipelines should only share the IR. " <>
          "See docs/architecture.md."

      true ->
        nil
    end
  end

  defp monitor_module?(name), do: String.starts_with?(name, "Accord.Monitor")
  defp tla_module?(name), do: String.starts_with?(name, "Accord.Pass.TLA")
end
