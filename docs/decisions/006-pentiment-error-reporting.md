# ADR-006: pentiment for structured error reporting

## Status

Accepted

## Context

Protocol violations need to be reported to developers in a way that is immediately actionable. A violation message like "invalid reply in state :locked" tells you what went wrong but not where to look. When a protocol has dozens of transitions across many states, locating the relevant declaration requires manual searching.

Approaches considered:

- **Plain string messages** -- simple to implement but provide no structural information. Cannot point to source code, cannot be programmatically parsed, and cannot be rendered differently depending on context (terminal vs. editor vs. CI).
- **Structured error tuples** -- carry metadata (file, line, message) but require each consumer to build its own formatting logic. Duplicates work across compile-time errors, runtime violations, and TLC result interpretation.
- **Pentiment diagnostics** -- the workspace's shared library for source-annotated diagnostics. Provides `Report` structs with labeled source spans, notes, and help text. A single `Pentiment.format/2` call renders the report with source context.

The accord project already depends on pentiment for compile-time validation errors (the pass pipeline uses `Pentiment.format/2` to render errors raised during `@before_compile`). Extending this to runtime violation reports gives a consistent diagnostic experience across both compile-time and runtime errors.

## Decision

Every IR node carries an optional `Pentiment.Span.t()` that records where it was declared in the protocol source file. Spans are captured during macro expansion and refined by the `RefineSpans` pass, which resolves deferred search spans (like `Pentiment.Span.Search`) against the source text.

The `Accord.Violation.Report` module converts `Violation` structs into pentiment `Report` structs:

1. A report is built from the violation kind, with notes describing what happened and help text suggesting what was expected.
2. If a compiled protocol is available, the transition's source span is looked up and attached as a primary label. For specific violation kinds, the label points at the most relevant part of the declaration (e.g., argument type violations point at the type annotation, not the whole transition).
3. The report is rendered with `Pentiment.format/2`, which reads the source file and produces output with inline code snippets, underlines, and margin annotations.

A strict mode (`strict: true`) raises on missing spans for violation kinds that should have them, catching span regressions in tests.

## Consequences

**Positive:**

- Violations point directly to the protocol source line that defines the violated contract. Developers see the relevant code without searching.
- Consistent format across compile-time errors, runtime violations, and property test failures. The same pentiment rendering is used everywhere.
- Reports carry structured metadata (notes, help, labels) that can be consumed by tools, editors, or AI agents, not just humans reading terminal output.
- Strict mode in tests ensures span coverage doesn't regress as new features are added.

**Negative:**

- Span tracking adds complexity to every macro and IR node. Each new DSL construct must capture its source location correctly.
- The source file must exist at report-rendering time for the code snippet to appear. In production deployments where source files are stripped, reports fall back to text-only diagnostics.
- Pentiment is a workspace-internal dependency. External users of accord inherit this dependency even if they don't use pentiment elsewhere.
