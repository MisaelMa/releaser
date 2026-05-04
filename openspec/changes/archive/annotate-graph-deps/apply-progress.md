# Apply Progress: annotate-graph-deps

## Status: COMPLETE

All 34 tasks done. Full test suite: 166 tests, 0 failures.

## Summary

### Phase 0 — Infrastructure / reconnaissance
- [x] 0.1 Confirmed test/mix/tasks/releaser_graph_test.exs did NOT exist
- [x] 0.2 Confirmed test/releaser/ui_test.exs did NOT exist
- [x] 0.3 Confirmed lib/releaser/graph.ex did NOT export level_map/1, dep_count/2, deep_count/2
- [x] 0.4 Confirmed lib/releaser/ui.ex did NOT export magenta/1 or blue/1

### Phase 1 — Releaser.Graph pure helpers
- [x] 1.1–1.3 Tests for level_map/1 (empty, single-level, multi-level)
- [x] 1.4 Implemented level_map/1
- [x] 1.5–1.6 Tests and implementation for dep_count/2
- [x] 1.7–1.11 Tests (including semantic pinning) and implementation for deep_count/2
- [x] 1.12 Refactor pass — no behavior change

### Phase 2 — Releaser.UI color helpers
- [x] 2.1 Created test/releaser/ui_test.exs with FAILING tests
- [x] 2.2–2.3 Tests for blue/1 and ANSI stripping
- [x] 2.4 Implemented magenta/1 and blue/1

### Phase 3 — Mix.Tasks.Releaser.Graph rendering
- [x] 3.1 Created test/mix/tasks/releaser_graph_test.exs
- [x] 3.2–3.4 Tests for annotation, bare leaves, and palette
- [x] 3.5–3.8 Implemented level_color/2, annotate_dep/3, wiring, and verification

### Phase 4 — Full verification
- [x] 4.1 mix test — 166 tests, 0 failures
- [x] 4.2 Manual run: mix releaser.graph shows bare leaf
- [x] 4.3 Visual inspection: colored output confirms palette cycling

### Phase 5 — Documentation
- [x] 5.1–5.3 Updated @moduledoc and @doc for all new functions

## Files changed
- lib/releaser/graph.ex — added level_map/1, dep_count/2, deep_count/2; updated @moduledoc
- lib/releaser/ui.ex — added magenta/1, blue/1
- lib/mix/tasks/releaser.graph.ex — added render_graph/1, level_color/2, annotate_dep/3; updated @moduledoc
- test/releaser/graph_test.exs — extended with 11 new tests
- test/releaser/ui_test.exs — CREATED with 8 tests
- test/mix/tasks/releaser_graph_test.exs — CREATED with 5 tests

## Last test run
166 tests, 0 failures (mix test — full suite)

## Deviations from design
- render_graph/1 is public (@doc false) to enable fixture-based integration testing. This is allowed per design; it remains invisible in generated docs.
