defmodule Accord.Checks.EnforceKeysOnStructs do
  @moduledoc """
  Checks that modules defining `defstruct` also set `@enforce_keys`.

  Structs without `@enforce_keys` allow incomplete initialization, which
  can lead to subtle runtime errors when required fields are missing.
  This check encourages explicit key enforcement on all struct definitions.
  """

  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      Structs should use @enforce_keys to prevent incomplete initialization.
      This catches missing fields at compile time rather than letting nils
      propagate to runtime. See Accord.IR for an example of the pattern.
      """
    ]

  @impl true
  def run(%Credo.SourceFile{} = source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.Code.prewalk(&traverse(&1, &2, issue_meta))
    |> Enum.uniq()
  end

  # Match a defmodule and inspect its body for defstruct without @enforce_keys.
  defp traverse(
         {:defmodule, _meta, [{:__aliases__, _, _aliases} | [do_block]]} = ast,
         issues,
         issue_meta
       ) do
    body = extract_body(do_block)
    new_issues = check_body(body, issue_meta)
    {ast, new_issues ++ issues}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp extract_body({:__block__, _, body}) when is_list(body), do: body
  defp extract_body([{:do, {:__block__, _, body}}]) when is_list(body), do: body
  defp extract_body([{:do, single}]), do: [single]
  defp extract_body(_), do: []

  # Scan the module body for defstruct calls and check for @enforce_keys.
  defp check_body(body, issue_meta) do
    has_enforce_keys = Enum.any?(body, &enforce_keys_attribute?/1)
    defstruct_nodes = Enum.filter(body, &defstruct_call?/1)

    if has_enforce_keys or defstruct_nodes == [] do
      []
    else
      Enum.map(defstruct_nodes, fn {:defstruct, meta, _} ->
        format_issue(
          issue_meta,
          message:
            "Structs should use @enforce_keys to prevent incomplete initialization. " <>
              "See Accord.IR for an example.",
          trigger: "defstruct",
          line_no: meta[:line]
        )
      end)
    end
  end

  defp defstruct_call?({:defstruct, _meta, _args}), do: true
  defp defstruct_call?(_), do: false

  defp enforce_keys_attribute?({:@, _, [{:enforce_keys, _, _}]}), do: true
  defp enforce_keys_attribute?(_), do: false
end
