# Proposal: annotate-graph-deps

## 1. Intent

`mix releaser.graph` (no-arg form) currently prints each app and a flat, color-only list of its direct project-internal deps. There is no signal about each dep's position in the dependency graph, so a developer scanning the output cannot answer "is this a leaf?", "how many subdeps does this dep pull in?", or "is this dep itself a hub?". We want to annotate each dep listed under each app with `<dep>[level][count][deep]`, where:

- `[level]` is the dep's topological level, colored per a deterministic level → color palette so eye-scanning the graph by level becomes trivial;
- `[count]` is the dep's direct project-internal dep count (dim);
- `[deep]` is a shallow count of which of those direct deps are themselves non-leaf nodes (dim).

True leaves (level 0, no deps) are printed as bare names with no annotation, keeping the output clean. Success means: running `mix releaser.graph` against the existing fixtures yields a level-tinted, annotated tree that is still legible without color (ANSI codes strip cleanly), and the annotation logic is independently unit-tested with strict TDD.

## 2. Scope

### IN

- `mix releaser.graph` — the no-argument form (levels view) renders annotations.
- 3 new pure helpers on `Releaser.Graph`:
  - `level_map/1` — invert `[{level, [name]}]` into `%{name => level}`.
  - `dep_count/2` — direct project-internal dep count for a name.
  - `deep_count/2` — shallow count of a name's direct deps that are themselves non-leaf.
- 2 new color helpers on `Releaser.UI`: `magenta/1`, `blue/1`.
- 2 private rendering helpers in `Mix.Tasks.Releaser.Graph`: `level_color/2` (cycles colors via `rem(level, 6)`) and `annotate_dep/3` (composes the bracket string).
- Full ExUnit coverage for the 3 new pure functions in `test/releaser/graph_test.exs` (TDD: tests written first).
- A NEW Mix task test file `test/mix/tasks/releaser_graph_test.exs` that captures shell output via `Mix.shell(Mix.Shell.Process)`, strips ANSI, and asserts on the rendered text shape (e.g. `csd[1][1][0]` appears, `openssl` appears bare).
- Documentation: module-doc and function-doc updates on the new `Graph` helpers.

### OUT

- `mix releaser.graph <app>` (the dependents-tree form) — annotation NOT applied. Different semantics (reverse graph), separate UX concern, deferred to a future change.
- `--no-color` / `NO_COLOR` env handling — pre-existing behavior of `Releaser.UI`. Not introduced or fixed by this change. Tests will assert on ANSI-stripped output to remain robust.
- Credo / Dialyxir setup — not in scope.
- Changes to `Workspace`, `App`, or any non-rendering code path.
- Caching / memoization of `dep_count`/`deep_count` — O(direct_deps × direct_deps_of_direct_dep), trivial for monorepo sizes.

## 3. Approach

**Approach 1 (RECOMMENDED) — pure helpers in `Graph`, rendering in the Mix task, color helpers in `UI`.**

Rationale:
- Keeps `Releaser.Graph` pure and dataflow-only. The new helpers (`level_map`, `dep_count`, `deep_count`) are self-contained, deterministic, testable in isolation.
- Keeps `Releaser.UI` as the single source of ANSI codes. Adding `magenta/1` and `blue/1` follows the exact pattern of the existing five color helpers — zero risk, zero new abstractions.
- Keeps display logic (`level_color/2`, `annotate_dep/3`) private to the Mix task because that's the only call site. No premature reusability.
- Each layer is independently testable: pure functions in `graph_test.exs`, ANSI-stripped output in `releaser_graph_test.exs`.

### Alternatives considered (rejected)

- **Approach 2: a richer `Graph.annotate/3` that returns a structured map.** Rejected — moves display concerns (the existence of an annotation) into a pure graph module. Over-engineered for one call site. Would also force the Mix task to know about the annotation map shape, leaking concerns the other way too. Revisit only if a second consumer appears.
- **Approach 3: also annotate the `<app>` dependents-tree form.** Rejected — different graph (reverse), `levels` is not currently computed in that branch, threading more state into `print_tree/4` adds coupling and surface area for what the user did not ask for. Out of scope; tracked as a follow-up.

## 4. Affected modules / files

| Path | Status | Change |
|------|--------|--------|
| `lib/releaser/graph.ex` | MODIFIED | Add 3 public functions: `level_map/1`, `dep_count/2`, `deep_count/2`. No changes to existing functions. |
| `lib/releaser/ui.ex` | MODIFIED | Add `magenta/1` and `blue/1`. Same pattern as existing color helpers. |
| `lib/mix/tasks/releaser.graph.ex` | MODIFIED | Replace dep-line construction in the levels rendering loop with new private helpers `level_color/2` and `annotate_dep/3`. The `<app>` branch (dependents tree) is untouched. |
| `test/releaser/graph_test.exs` | MODIFIED | Add ExUnit tests for the 3 new pure functions. Existing tests untouched. |
| `test/mix/tasks/releaser_graph_test.exs` | NEW | First test file for the Mix task. Establishes the `Mix.shell(Mix.Shell.Process)` capture pattern for future task tests. |

## 5. Color palette

Deterministic mapping, cycling at level 6 via `rem(level, 6)`:

| Level | ANSI color | UI helper | Status |
|-------|-----------|-----------|--------|
| 0 | cyan | `UI.cyan/1` | already exists |
| 1 | green | `UI.green/1` | already exists |
| 2 | yellow | `UI.yellow/1` | already exists |
| 3 | magenta | `UI.magenta/1` | NEW |
| 4 | red | `UI.red/1` | already exists |
| 5 | blue | `UI.blue/1` | NEW |
| 6 | cyan (cycle) | `UI.cyan/1` | via `rem(6, 6) == 0` |
| 7 | green (cycle) | `UI.green/1` | via `rem(7, 6) == 1` |
| n | `rem(n, 6)` → row above |  |  |

The `[count]` and `[deep]` brackets are always rendered with `UI.dim/1` (subdued, secondary information).

Cycle behavior at level 6+ is deterministic (`rem/2`), keeps the palette to colors already familiar in the codebase, and avoids exotic ANSI codes that may not render well in all terminals. Real monorepos rarely exceed 5 levels; the cycle is a safety net, not a primary case.

## 6. Naming clarification — `deep_count`

The exploration flagged that `deep_count` may mislead because it is **shallow**: it counts how many of a name's direct deps are themselves non-leaf, NOT a recursive descent.

**Decision: keep `deep_count`.**

Reasoning:
1. The user's spec for the rendered output uses `[deep]` as the third bracket label. Keeping the function name aligned with the visible label maintains traceability between code and UI.
2. The `@doc` will be explicit: "Returns a shallow count — the number of `name`'s direct deps that themselves have at least one project-internal subdep. Not a recursive depth metric."
3. Rejected alternatives: `subdep_count` (ambiguous — sounds like total transitive count), `indirect_dep_count` (same ambiguity), `nonleaf_dep_count` (accurate but verbose, breaks the parallel with `dep_count`).

The tests will pin the semantics by name and by example, so any future reader who misreads the name gets corrected by the test suite immediately.

## 7. Rollback plan

This change is display-only at runtime. Two-tier rollback:

1. **Hot rollback (UI bug discovered):** revert `lib/mix/tasks/releaser.graph.ex` to its pre-change state. The new public functions on `Releaser.Graph` and `Releaser.UI` are pure, additive, and unused by anything else — they can stay. No data migration, no state cleanup.
2. **Full rollback (semantics flaw discovered):** revert all five files in one commit. The change is small enough that a single revert is clean.

No persistent state, no on-disk artifacts, no API surface exposed to library consumers (Mix tasks are end-user tools, not part of the library's public API). Risk surface is contained to terminal output of one Mix task invocation form.

## 8. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| ANSI codes leak into CI logs / test assertions | Medium | Low | Tests strip ANSI before asserting (use a small `strip_ansi/1` helper or `String.replace/3` on the regex `~r/\e\[[0-9;]*m/`). Pre-existing behavior for the rest of the codebase is unchanged — this is a test-side concern only. |
| Strict TDD compliance — test-first for new helpers | High (process) | Low | Establish the order explicitly in tasks: write test in `graph_test.exs` → assert it fails → implement helper → assert it passes. Same for the Mix task test before changing rendering. The `sdd-apply` agent runs in Strict TDD Mode and will enforce this. |
| Mix task is currently test-less; new test file pattern needs to be established | Medium | Medium | Use `Mix.shell(Mix.Shell.Process)` + `assert_receive {:mix_shell, :info, [line]}` (or capture via `ExUnit.CaptureIO`) and a local `strip_ansi/1`. Document the pattern inline in the new test file as a reference for future task tests. |
| Color palette cycling beyond level 5 may confuse readers | Low | Low | Real monorepos rarely exceed 5 levels. The cycle is documented in the function's `@doc` and the proposal's color table. If it becomes a real complaint, future change can introduce more colors or a non-cyclic strategy. |
| `deep_count` name confusion | Low | Low | Pinned via `@doc` and tests with explicit examples. See section 6. |
| Existing `graph_test.exs` regressions | Very low | Low | Only ADDING tests; existing assertions untouched. New helpers are independent of existing functions. |

## 9. Conventional Commit type

```
feat(graph): annotate deps with [level][count][deep] markers
```

Per the project's `bump_rules`, `feat` triggers a **minor** bump. This is correct: the change adds user-visible functionality to a Mix task and adds new public functions to `Releaser.Graph` and `Releaser.UI`, all backwards-compatible.

If the change ends up split across multiple commits during apply (e.g. one for `Graph` helpers, one for `UI` helpers, one for the task), the user-facing one carries `feat(graph):` and the others can be `feat(ui):` and `feat(graph): wire annotations into mix task` — all `feat`, all minor-eligible, no breaking changes.

## 10. Ready for next phase

Yes. The next phases (`sdd-spec` and `sdd-design`) can run in parallel:
- `sdd-spec` will translate this into capability/scenario specs (the three pure helpers are highly spec-able with input/output examples; the rendering has a clean "given fixtures → assert annotated text" scenario).
- `sdd-design` will lock the function signatures, the color cycling implementation, and the test-capture pattern.
