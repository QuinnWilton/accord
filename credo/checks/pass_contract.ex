defmodule Accord.Checks.PassContract do
  @moduledoc """
  Checks that validation pass modules define a `run/1` function.

  Modules under `Accord.Pass.*` (excluding `Accord.Pass.Helpers` and
  `Accord.Pass.TLA.*`) are expected to implement a `run/1` function that
  returns `{:ok, ir} | {:error, [Report.t()]}`. This check verifies the
  function is present in the module's AST.
  """

  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Validation pass modules must define a run/1 function that returns
      {:ok, ir} | {:error, [Report.t()]}. This ensures all passes conform
      to the pipeline contract used by Accord.Protocol.compile_ir/2.
      """
    ]

  @impl true
  def run(%Credo.SourceFile{} = source_file, params \\ []) do
    # Only check files in lib/. Test modules may define Accord.Pass.* modules
    # (like Accord.Pass.ValidateStructureTest) that are not passes.
    if test_file?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta))
      |> Enum.uniq()
    end
  end

  defp test_file?(nil), do: false

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.starts_with?(filename, "test/")
  end

  # Match a top-level defmodule and check if it is a pass module that
  # needs a run/1 function.
  defp traverse(
         {:defmodule, meta, [{:__aliases__, _, aliases} | [do_block]]} = ast,
         issues,
         issue_meta
       )
       when is_list(aliases) do
    module_name = Enum.map_join(aliases, ".", &to_string/1)

    if pass_module?(module_name) and not has_run_1?(do_block) do
      issue =
        format_issue(
          issue_meta,
          message:
            "Validation pass modules must define a run/1 function that returns " <>
              "{:ok, ir} | {:error, [Report.t()]}. " <>
              "See Accord.Pass.ValidateStructure for an example.",
          trigger: module_name,
          line_no: meta[:line]
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  # A module qualifies as a pass module if it matches Accord.Pass.*
  # but is not Accord.Pass.Helpers and not under Accord.Pass.TLA.* or
  # Accord.Pass.Monitor.* (those passes have a different contract).
  defp pass_module?(name) do
    String.starts_with?(name, "Accord.Pass.") and
      name != "Accord.Pass.Helpers" and
      not String.starts_with?(name, "Accord.Pass.TLA.") and
      not String.starts_with?(name, "Accord.Pass.Monitor.")
  end

  # Walk the do-block AST looking for a `def run(...)` with arity 1.
  defp has_run_1?({:__block__, _, body}) when is_list(body) do
    Enum.any?(body, &defines_run_1?/1)
  end

  defp has_run_1?([{:do, {:__block__, _, body}}]) when is_list(body) do
    Enum.any?(body, &defines_run_1?/1)
  end

  defp has_run_1?([{:do, single}]) do
    defines_run_1?(single)
  end

  defp has_run_1?(_), do: false

  # def run(single_arg) with any body.
  defp defines_run_1?({:def, _, [{:run, _, [_single_arg]}, _body]}), do: true

  # def run(single_arg) when ... do.
  defp defines_run_1?({:def, _, [{:when, _, [{:run, _, [_single_arg]} | _]}, _body]}), do: true

  defp defines_run_1?(_), do: false
end
