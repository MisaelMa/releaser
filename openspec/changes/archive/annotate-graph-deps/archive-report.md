# Archive Report: annotate-graph-deps

**Change**: annotate-graph-deps
**Archived**: 2026-05-04
**Status**: COMPLETE
**Verify result**: PASS WITH WARNINGS

---

## Executive Summary

Successfully delivered annotated dependency graph rendering for `mix releaser.graph` (levels view). Added three pure helpers to `Releaser.Graph` (`level_map/1`, `dep_count/2`, `deep_count/2`), two color helpers to `Releaser.UI` (`magenta/1`, `blue/1`), and rendering integration in `Mix.Tasks.Releaser.Graph`. All 34 tasks completed via Strict TDD. 166 tests pass, 0 failures. No CRITICAL findings. Two non-blocking suggestions logged.

---

## Artifacts Delivered

### Code Changes

- **lib/releaser/graph.ex** — Added three public helpers:
  - `level_map/1` — converts `[{level, [name]}]` to `%{name => level}`
  - `dep_count/2` — direct dep count for a name in a graph
  - `deep_count/2` — shallow count of non-leaf direct deps
  
- **lib/releaser/ui.ex** — Added two color helpers:
  - `magenta/1` — ANSI magenta wrapper (new)
  - `blue/1` — ANSI blue wrapper (new)
  
- **lib/mix/tasks/releaser.graph.ex** — Rendering integration:
  - `render_graph/1` — public @doc false entry point for fixture testing
  - `level_color/2` — private helper for level → color cycling via `rem(level, 6)`
  - `annotate_dep/3` — private helper to build annotated bracket string
  - Modified `run([])` branch to use `annotate_dep/3` for non-leaf deps
  - `run([app_name])` branch unchanged (no annotation in dependents-tree form)

### Test Files (New)

- **test/releaser/ui_test.exs** (NEW) — 8 tests for `magenta/1`, `blue/1`, ANSI stripping
- **test/mix/tasks/releaser_graph_test.exs** (NEW) — 5 integration tests using `Mix.shell(Mix.Shell.Process)` capture pattern
- **test/releaser/graph_test.exs** (Extended) — 11 new tests for the three helpers

### Test Results

- **Total**: 166 tests
- **Passed**: 166
- **Failed**: 0
- **Skipped**: 0

### Main Specs Created (Merged from Delta)

- **openspec/specs/graph.md** — Public API contract for `Releaser.Graph` helpers
- **openspec/specs/ui.md** — Public API contract for UI color helpers
- **openspec/specs/mix-tasks.md** — Public API contract for Mix task rendering

---

## Spec Compliance

16/16 scenarios compliant. Full mapping:

| Requirement | Scenarios | Status |
|-------------|-----------|--------|
| R1: level_map/1 | 1.1–1.3 | PASS |
| R2: dep_count/2 | 2.1–2.3 | PASS |
| R3: deep_count/2 | 3.1–3.4 | PASS |
| R4: magenta/1, blue/1 | 4.1–4.3 | PASS |
| R5: annotated rendering | 5.1–5.3 | PASS |
| R6: level-color cycling | 6.1–6.4 | PASS |

---

## Verification Status

**PASS WITH WARNINGS** — No CRITICAL findings.

### Warnings
- **W1**: `render_graph/1` is @doc false public instead of defp. Controlled deviation pre-approved in design. No behavior impact.

### Suggestions (Non-blocking)
- **S1**: Scenarios 6.1–6.3 (color cycling) confirmed via code inspection, not via color-specific automated tests (ANSI stripped before assertion). All bracket colors structurally present in code.
- **S2**: `collect_output/0` in task test uses `after 0` (works for sync tests; would miss async output in future scenarios).

---

## Files Modified / Created

| Path | Type | Change |
|------|------|--------|
| `lib/releaser/graph.ex` | MODIFIED | +3 public functions, +@moduledoc |
| `lib/releaser/ui.ex` | MODIFIED | +2 public functions |
| `lib/mix/tasks/releaser.graph.ex` | MODIFIED | +3 private helpers, refactor render loop |
| `test/releaser/graph_test.exs` | EXTENDED | +11 tests |
| `test/releaser/ui_test.exs` | CREATED | 8 tests (new file) |
| `test/mix/tasks/releaser_graph_test.exs` | CREATED | 5 tests (new file) |
| `openspec/specs/graph.md` | CREATED | Merged main spec from delta |
| `openspec/specs/ui.md` | CREATED | Merged main spec from delta |
| `openspec/specs/mix-tasks.md` | CREATED | Merged main spec from delta |

---

## Design Adherence

All 7 Architecture Decision Records (ADRs) followed:

- **D1**: Pure helpers in `Releaser.Graph` ✓
- **D2**: Rendering helpers private (`defp`) ✓
- **D3**: Color cycling via `rem(level, 6)` ✓
- **D4**: `deep_count/2` is shallow, not recursive ✓
- **D5**: No raw `IO.ANSI` in task ✓
- **D6**: ANSI stripping via regex in tests ✓
- **D7**: `Mix.shell(Mix.Shell.Process)` capture pattern ✓

---

## Integration Summary

- **Conventional Commit type**: `feat(graph): annotate deps with [level][count][deep] markers`
- **Scope of change**: Levels view rendering only; dependents-tree form untouched
- **Backward compatibility**: YES (additive; no breaking changes to existing APIs)
- **No cyclic deps, unstable levels detected**: All fixtures pass topological sort

---

## Approval Gate

Change approved for commit. No blockers. Two suggestions logged as future enhancements (color-specific tests, async-aware collection).

---

## Observation References (Engram)

- Proposal: #29 (sdd/annotate-graph-deps/proposal)
- Spec: #30 (sdd/annotate-graph-deps/spec)
- Design: #31 (sdd/annotate-graph-deps/design)
- Tasks: #32 (sdd/annotate-graph-deps/tasks)
- Apply-progress: #33 (sdd/annotate-graph-deps/apply-progress)
- Verify-report: #34 (sdd/annotate-graph-deps/verify-report)
- Archive-report: #35 (sdd/annotate-graph-deps/archive-report)

---

**Archive completed**: 2026-05-04  
**Next step**: Commit with prepared Conventional Commit message and include openspec/ changes in the changeset.
