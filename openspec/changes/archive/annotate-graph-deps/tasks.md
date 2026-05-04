# Tasks: annotate-graph-deps

**Total tasks**: 34 (28 implementation/test + 3 verification + 3 documentation)
**Strict TDD**: every implementation task is preceded by its red-test task.
**Status**: ALL COMPLETE
**Test result**: 166 tests, 0 failures

## Phase 0 — Infrastructure / reconnaissance

- [x] 0.1 Confirmed test/mix/tasks/releaser_graph_test.exs did NOT exist
- [x] 0.2 Confirmed test/releaser/ui_test.exs did NOT exist
- [x] 0.3 Confirmed lib/releaser/graph.ex did NOT export level_map/1, dep_count/2, deep_count/2
- [x] 0.4 Confirmed lib/releaser/ui.ex did NOT export magenta/1 or blue/1

## Phase 1 — Releaser.Graph pure helpers (TDD, sequential)

- [x] 1.1 Write FAILING test for level_map/1 — multi-level input
- [x] 1.2 Write FAILING test for level_map/1 — empty input
- [x] 1.3 Write FAILING test for level_map/1 — single level
- [x] 1.4 Implement level_map/1 — GREEN
- [x] 1.5 Write FAILING tests for dep_count/2 — known+deps, leaf, unknown
- [x] 1.6 Implement dep_count/2 — GREEN
- [x] 1.7 Write FAILING test for deep_count/2 — 3-node chain semantic pin
- [x] 1.8 Write FAILING test for deep_count/2 — leaf returns 0
- [x] 1.9 Write FAILING test for deep_count/2 — unknown name returns 0
- [x] 1.10 Write FAILING test for deep_count/2 — multiple qualifying direct deps
- [x] 1.11 Implement deep_count/2 — GREEN. @doc states SHALLOW, NOT recursive
- [x] 1.12 Refactor pass — no behavior change

## Phase 2 — Releaser.UI color helpers (TDD, independent of Phase 1)

- [x] 2.1 Create test/releaser/ui_test.exs with FAILING tests for magenta/1
- [x] 2.2 Write FAILING test for blue/1
- [x] 2.3 Write FAILING test for ANSI stripping both helpers
- [x] 2.4 Implement magenta/1 and blue/1 — GREEN

## Phase 3 — Mix.Tasks.Releaser.Graph rendering (TDD, depends on 1 AND 2)

- [x] 3.1 Create test/mix/tasks/releaser_graph_test.exs — FAILING test for leaf has no brackets
- [x] 3.2 Write FAILING test: non-leaf dep annotated with csd[1][1][0]
- [x] 3.3 Write FAILING test: run([app_name]) produces no bracket annotations
- [x] 3.4 Write FAILING tests for level_color palette cycling
- [x] 3.5 Implement defp level_color/2
- [x] 3.6 Implement defp annotate_dep/3
- [x] 3.7 Wire into run([]) via render_graph/1 — tests GREEN
- [x] 3.8 Verify run([app_name]) branch unchanged — test GREEN

## Phase 4 — Full verification

- [x] 4.1 Run mix test — 166 tests, 0 failures
- [x] 4.2 Manual: run mix releaser.graph — releaser appears as bare leaf (no brackets)
- [x] 4.3 Visual: inspect output for multiple levels, confirm colored brackets

## Phase 5 — Documentation

- [x] 5.1 Updated @moduledoc of Releaser.Graph to mention three new helpers
- [x] 5.2 Added @doc on level_map/1, dep_count/2, deep_count/2 with Examples blocks. deep_count pinned SHALLOW semantics
- [x] 5.3 Updated @moduledoc of Mix.Tasks.Releaser.Graph with annotation format docs
