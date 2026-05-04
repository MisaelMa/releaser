# Design: annotate-graph-deps

## 0. Executive summary

Render an annotated dependency graph by adding three pure helpers to `Releaser.Graph` (`level_map/1`, `dep_count/2`, `deep_count/2`), two color helpers to `Releaser.UI` (`magenta/1`, `blue/1`), and two private rendering helpers (`level_color/2`, `annotate_dep/3`) inside `Mix.Tasks.Releaser.Graph`. Color cycles every 6 levels via `rem(level, 6)`. Tests are split: pure-function unit tests in `graph_test.exs` and `ui_test.exs` (NEW), plus an integration test in `releaser_graph_test.exs` (NEW) that captures `Mix.shell(Mix.Shell.Process)` output and asserts on ANSI-stripped text.

## 1. Architecture decisions (ADRs)

- **D1**: Pure helpers in `Releaser.Graph`, not in the Mix task or new module
- **D2**: Rendering helpers stay PRIVATE in `Mix.Tasks.Releaser.Graph`
- **D3**: Color cycling via `rem(level, 6)` instead of saturating at level 5
- **D4**: `deep_count/2` is SHALLOW (one-level lookahead), NOT recursive
- **D5**: All color decisions through `Releaser.UI` helpers; NO raw `IO.ANSI` in the Mix task
- **D6**: ANSI stripping in tests via local `strip_ansi/1` helper
- **D7**: Mix task tests use `Mix.shell(Mix.Shell.Process)` capture pattern

All seven ADRs were followed in implementation.

## 2. Module signatures (confirmed implemented)

- `Releaser.Graph.level_map/1` — `levels() :: %{name() => non_neg_integer()}`
- `Releaser.Graph.dep_count/2` — `(name(), graph()) :: non_neg_integer()`
- `Releaser.Graph.deep_count/2` — `(name(), graph()) :: non_neg_integer()`
- `Releaser.UI.magenta/1` — wraps text with ANSI magenta
- `Releaser.UI.blue/1` — wraps text with ANSI blue
- `Mix.Tasks.Releaser.Graph.level_color/2` (defp) — maps level to colored bracket
- `Mix.Tasks.Releaser.Graph.annotate_dep/3` (defp) — composes annotated dep string

## 3. Test strategy (Strict TDD)

Layer 1: `test/releaser/graph_test.exs` — unit tests for three helpers (11 new tests)
Layer 2: `test/releaser/ui_test.exs` (NEW) — unit tests for color helpers (8 tests)
Layer 3: `test/mix/tasks/releaser_graph_test.exs` (NEW) — integration tests (5 tests)

All 34 tasks completed via test-first approach.

## 4. Color palette (confirmed)

| rem(level, 6) | UI helper | Status |
|---|---|---|
| 0 | `UI.cyan/1` | exists |
| 1 | `UI.green/1` | exists |
| 2 | `UI.yellow/1` | exists |
| 3 | `UI.magenta/1` | NEW |
| 4 | `UI.red/1` | exists |
| 5 | `UI.blue/1` | NEW |

## 5. Edge cases handled

- Empty workspace: `levels = []`, no crash
- Single app, no deps: printed bare (level-0 leaf)
- Dep name not in level_map: defensive default to level 0
- Level 6+ graphs: color cycles via `rem/2`
- Empty strings to `magenta/1` / `blue/1`: handled without crash

## 6. Risks mitigated

- ANSI stripping in tests via `Regex.replace(~r/\e\[[0-9;]*m/, ...)`
- No name conflicts with existing UI helpers
- New UI test file establishes pattern for future tests
- `deep_count` semantics pinned via @doc and 3-level chain test

## 7. Rendering flow (implemented)

```
Graph.level_map(levels) → %{name => level}
for each dep:
  annotate_dep(dep, graph, lmap)
    → if all-zero: bare name
    → else: name <> level_color("[#{lvl}]") <> dim("[#{cnt}][#{dpc}]")
      → level_color maps rem(level, 6) to UI helper
```

## 8. Out of scope

- `mix releaser.graph <app>` (dependents-tree form)
- `--no-color` / `NO_COLOR` env handling
- Memoization of dep_count/deep_count
- Regression tests for existing UI helpers

## 9. Verification summary

166 tests, 0 failures. All 16 spec scenarios compliant. 7/7 ADRs followed (1 pre-approved deviation: render_graph/1 is @doc false public instead of defp). No CRITICAL findings. Two non-blocking suggestions logged.
