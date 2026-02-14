## Summary

-
-
-

## Motivation

<!-- Why is this change needed? What problem does it solve? -->

## Checklist

- [ ] Tests pass (`mix test`)
- [ ] Format clean (`mix format --check-formatted`)
- [ ] Dialyzer clean (`mix dialyzer`)
- [ ] Compiles without warnings (`mix compile --warnings-as-errors`)
- [ ] No cross-boundary imports (Monitor <-> TLA passes)
- [ ] New validation passes follow the `{:ok, ir} | {:error, [Report.t()]}` contract
- [ ] New error codes documented (if applicable)
- [ ] CLAUDE.md updated (if architecture changed)
- [ ] Typespecs on all new public functions

## Test plan

<!-- How was this change tested? Include relevant test files or describe manual verification. -->
