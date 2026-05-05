# Proposal: block-publish-non-publishable-deps

## 1. Intent

Stop releaser from publishing apps whose dependency closure contains non-publishable apps, and surface that fact clearly in `mix releaser.graph` and `mix releaser.publish`. When app A (`publish: true`) depends — directly or transitively — on app B (`publish: false`), A is "blocked": releaser must skip it and tell the user **why**, naming the offending dep(s).

## 2. Motivation

Today, `Releaser.Publisher.plan/1` silently strips non-publishable names from each publishable app's `:deps` list before topological sorting and path-dep replacement. The user observes:

- `mix releaser.graph` renders `[publish: ✓]` (green) for an app that **cannot** be safely published, because its mix.exs after path-dep replacement would reference a non-published version.
- `mix releaser.publish` happily publishes that app with a structurally incomplete dep list — a real correctness bug, not a UX nit.

The exploration also surfaced a CRITICAL finding: the existing fixture `@rich_apps` in `test/mix/tasks/releaser_graph_test.exs` (csd → openssl, where openssl has `publish: false`) is the canonical blocking scenario, and the assertion at line 85 currently encodes the wrong behavior as expected. Today's tests validate the bug. This change inverts that.

User's framing: **"necesitamos mostrar que no se publicará por que sus subdependencias no se publicaran"** — the fix must be visible (graph badge) AND enforced (publisher excludes blocked apps). Half-measures are off the table.

## 3. Scope

### In scope

- Detect transitively blocked apps inside `Releaser.Publisher.plan/1` using an iterative worklist over the workspace.
- Add a new skipped entry shape with `reason: :blocked_by_deps` and a `blocked_by: [name, ...]` field listing the immediate blocking dep(s).
- Expose `Releaser.Publisher.blocked_names/1` (or equivalent public helper inside Publisher) so the graph task can derive the same set without duplicating logic.
- Update `mix releaser.graph` compact and detailed renderers to show a "blocked" state distinct from `[publish: ✓]` and `[publish: ✗]`.
- Update the graph summary counter to reflect *effectively publishable* apps and add a separate "Blocked" line.
- Update `mix releaser.publish` skipped-entry renderer to handle the `:blocked_by_deps` reason and show the blocking deps.
- Invert the existing `releaser_graph_test.exs:85` assertion (csd is now `[publish: ✗ blocked]`).
- Add tests covering: direct blocking, transitive blocking (A → C → B), all-blocked workspace, and graph badge / summary rendering.

### Out of scope

- The dependents tree view in `mix releaser.graph <app>`. It uses a different rendering pipeline; treat blocked-status display there as a separate, lower-value change if requested later.
- A new top-level `Releaser.PublishFilter` module. The semantics are publishing semantics; they live in Publisher until duplication forces extraction.
- Any change to `%Releaser.App{}` struct shape. Blocked status is computed, not stored.
- Hex status, version-form, prerelease, or other badge logic. Those branches stay untouched.
- CLI flags to ignore/override blocking (e.g. `--allow-blocked`). If demanded later, separate change.

## 4. Approach (high level)

1. **Detection — iterative worklist in `Publisher.plan/1`**
   - Build `non_publishable_names = MapSet of app.name where publish == false`.
   - Seed `blocked` with publishable apps whose direct `:deps` intersect `non_publishable_names`.
   - Loop: a publishable app whose `:deps` intersect `blocked` joins `blocked`. Stop when the set stops growing. Bounded by app count, terminates on cycles.
   - Result: `safe_to_publish = publishable_apps \ blocked`.

2. **Plan output**
   - `to_publish` is built from `safe_to_publish` after the existing Hex-status filtering (`:ahead | :unpublished`).
   - Blocked apps go into `skipped_entries` as `%{app: name, local: version, hex: nil, reason: :blocked_by_deps, blocked_by: [name, ...]}`. `blocked_by` lists the immediate non-publishable deps OR the immediate blocked deps that caused inclusion (whichever is the direct cause for that app — see design phase for the precise rule).

3. **Public helper for graph task**
   - `Publisher.blocked_names/1` accepts the workspace apps and returns a MapSet of blocked names. Internally calls the same worklist.
   - The graph task calls it once per render and threads the MapSet to `compact_badges/2` and the detailed renderer.

4. **Badges (Option B from explore)**
   - Compact: `[publish: ✗ blocked]` (red).
   - Detailed: `publish: blocked (needs: foo, bar)` (red).
   - Untouched: `[publish: ✓]` (green) for publishable & not blocked, `[publish: ✗]` (dim) for `publish: false`.

5. **Summary**
   - Replace the single "Publishable apps: N" counter with two lines: "Publishable: N" (where N excludes blocked) and "Blocked by deps: M" (omit the line when M = 0). Wording finalized in spec/design.

6. **Publish task**
   - Add a `:blocked_by_deps` branch in `skipped` rendering: e.g. `~ {app} skipped — blocked by non-publishable deps: foo, bar`. Final phrasing in spec.

## 5. Resolved questions

### Q1 — `blocked_by:` field in skipped entries

**Resolution: ADOPT.** Add `blocked_by: [name, ...]` to skipped entries with `reason: :blocked_by_deps`.

**Reasoning:** Only one consumer reads `skipped` (`releaser.publish.ex`). The shape change is contained. Without `blocked_by` the user sees "skipped — blocked" with no actionable info; they must run `mix releaser.graph` and reason themselves about who's at fault. That defeats the point of the change. The whole motivation is **visibility**.

### Q2 — Summary counter

**Resolution: SUBTRACT blocked from "Publishable" AND add a separate "Blocked" line.**

**Reasoning:** The status quo lies — it reports as publishable apps that releaser will refuse to publish. Subtracting fixes the lie. Adding a separate line preserves the information ("how many are blocked?") which the user needs to act. Hiding the count behind a single number would force users to count blocked apps manually from the per-app badges. We're optimizing for "user understands the workspace at a glance" and that requires both numbers.

### Q3 — `Publisher.blocked_names/1` cross-module call from the graph task

**Resolution: KEEP IT IN `Releaser.Publisher`. No new `Releaser.PublishFilter` module.**

**Reasoning:** The semantics ARE publish semantics. "Which apps are blocked from being published" is a Publisher question by definition. Extracting a `PublishFilter` module before there's a second caller would be premature abstraction — adds a file, adds a name, doesn't pay rent. The `Publisher.blocked_names/1` function is a clean, narrow public API. If a third consumer appears (e.g. a future `mix releaser.status` task) AND the algorithm grows non-trivially, *then* extract. YAGNI applies until evidence says otherwise.

### Q4 — Dependents tree (`mix releaser.graph <app>`)

**Resolution: DEFER.** Out of scope for this change.

**Reasoning:** Different rendering pipeline (line-tree, not badge list), low signal-to-noise (the dependents view is about "who depends on X", not "is X publishable"), and shipping this change without it still solves the user's stated problem. If a user requests it, open a follow-up change. Trying to do it now risks scope creep and a fuzzier verification surface.

## 6. Behavior changes (what users will observe differently)

- **Graph compact badge** for an app that is publishable but has a non-publishable dep in its closure: `[publish: ✗ blocked]` (red), instead of today's misleading `[publish: ✓]`.
- **Graph detailed line** for the same app: `publish: blocked (needs: foo, bar)` (red), instead of today's `publish: yes`.
- **Graph summary**: "Publishable: N" now subtracts blocked apps; a new line "Blocked by deps: M" appears when M > 0.
- **`mix releaser.publish`** no longer publishes blocked apps. They appear in the skipped section with a new line: `~ {app} skipped — blocked by non-publishable deps: foo, bar`.
- **`Publisher.plan/1` return value**: `skipped` may contain entries with `reason: :blocked_by_deps` (new value) and a `blocked_by: [name, ...]` field (new key, only present on this reason).
- **`Publisher.plan/1` filtering**: the silent stripping of non-publishable names from each app's `:deps` (publisher.ex:34) is GONE. Blocked apps are surfaced; non-blocked apps keep their full dep list (which by construction contains only publishable names anyway, since blocked apps are excluded from `to_publish`).

## 7. Backwards compatibility

- **Test inversion (intentional, not a regression):** `test/mix/tasks/releaser_graph_test.exs:85` currently asserts `csd v2.0.0 [publish: ✓]`. After this change it MUST assert `[publish: ✗ blocked]`. The existing test encodes the bug as expected behavior; flipping it is the *point* of this change. The proposal calls this out so reviewers don't read the diff as breakage.

- **Skipped-entry shape:** A new `reason` value (`:blocked_by_deps`) and a new optional key (`blocked_by`) are added. Anyone pattern-matching exhaustively on skipped entry reasons outside releaser would now miss `:blocked_by_deps`. Risk is low — releaser is library code at a maturity where exhaustive matching on internal plan output is not an expected external contract. Internal consumer (`releaser.publish.ex`) is updated in the same change.

- **`Publisher.plan/1` public shape:** `levels`, `apps`, `skipped` keys unchanged. Only the contents of `skipped` evolve. No breakage for callers that iterate `skipped` and render `entry.app` / `entry.reason` defensively.

- **CLI surface:** Unchanged. No new flags, no removed flags. `--only`, `--dry-run`, `--hex` all work as before; `--only` operates on the post-blocking `to_publish` list (correct by construction — you can't `--only` an app that is itself blocked, and that's the right behavior).

## 8. Risks

- **`blocked_by` semantics ambiguity.** For a transitively blocked app A (A → C → B, B non-publishable), is `blocked_by` = `[C]` (immediate cause) or `[B]` (root cause)? Spec must pin this down. Proposal default: immediate cause (the dep that *appears in A's `:deps`* and is itself blocked or non-publishable). Rationale: matches what the user sees in their own mix.exs.

- **Summary wording bikeshed.** "Publishable" vs. "Effectively publishable" vs. "Will publish". Spec phase decides; this is presentation, not architecture.

- **Color/symbol coupling with UI module.** Graph task uses `UI.green/red/dim`. New `[publish: ✗ blocked]` state needs `UI.red`. If the UI module lacks a red helper, design phase adds one — minor.

- **Performance of worklist on large workspaces.** Bounded by O(apps × deps) per iteration, O(apps) iterations worst case → O(apps² × max_deps). Releaser workspaces are dozens of apps at most. Non-issue, but call it out so we don't optimize prematurely.

- **Future `--allow-blocked` escape hatch.** Some users may want to override (e.g. CI workflows where a non-publishable app is intentionally vendored). Not adding it now keeps the surface clean. If demand appears, separate change.

- **Cross-module coupling cost.** Graph task now depends on `Publisher.blocked_names/1`. Acceptable per Q3, but worth re-evaluating if a third consumer appears.

## 9. Acceptance criteria (high level)

The change ships when all of the following are true. Spec phase converts these into testable scenarios.

1. `Releaser.Publisher.plan/1` excludes from `to_publish` any publishable app whose `:deps` closure contains a non-publishable name (direct OR transitive).
2. Such excluded apps appear in `skipped` with `reason: :blocked_by_deps` and a non-empty `blocked_by` list.
3. `Releaser.Publisher.blocked_names/1` (public) returns a MapSet of blocked app names for a given workspace apps list, matching the set used internally by `plan/1`.
4. `mix releaser.graph` compact badge renders `[publish: ✗ blocked]` (red) for a blocked app, `[publish: ✓]` for a non-blocked publishable app, `[publish: ✗]` for a non-publishable app — unchanged for the latter two.
5. `mix releaser.graph` detailed renderer shows `publish: blocked (needs: <comma-list>)` for a blocked app.
6. `mix releaser.graph` summary subtracts blocked apps from the "publishable" count and renders a "Blocked" count line when M > 0.
7. `mix releaser.publish` does not publish blocked apps. Its skipped section names them and lists their blocking deps.
8. The existing `releaser_graph_test.exs:85` assertion is updated to expect the blocked badge.
9. New tests cover: direct block, transitive block (A → C → B), workspace where every publishable app is blocked, and graph badge/summary rendering for all three.
10. `mix test` passes. No new compile warnings introduced by this change.
