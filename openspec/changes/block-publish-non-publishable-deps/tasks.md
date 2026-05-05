# Tasks: block-publish-non-publishable-deps

**Total tasks**: 54
**Strict TDD**: every implementation task is preceded by its red-test task.
**Phases**: 0 (recon), 1 (blocked_names/blocked_with_reasons), 2 (plan/1 integration), 3 (compact badge), 4 (detailed line), 5 (summary), 6 (publish task renderer), 7 (verify), 8 (docs)
**Status**: not-started

---

## Phase 0 — Reconnaissance (no code; reads only)

- [ ] 0.1 RECON: Confirm `UI.red/1` exists in `lib/releaser/ui.ex`. Design says line 13: `def red(text)`. Verify the clause is present and returns an ANSI-escaped string. (No code change — finding confirms Phase 3 requires no UI changes.)
- [ ] 0.2 RECON: Read `test/releaser/publisher_test.exs`. Confirm no existing `describe "blocked_names/1"` or `describe "plan/1 — blocking detection"` block exists. Identify the existing `describe "plan/1 — Hex status filtering"` block so Phase 2 tasks know where to insert without colliding.
- [ ] 0.3 RECON: Read `test/mix/tasks/releaser_graph_test.exs`. Note exact content at lines 82–99 (compact badge assertions), 128–135 (detailed publish line), and 177–185 (summary block). These four locations will be modified in Phase 3–5 and must be treated as INTENTIONAL INVERSIONS — not regressions.
- [ ] 0.4 RECON: Confirm `test/mix/tasks/releaser_publish_test.exs` does NOT exist. If it exists, note existing test structure. Phase 6 will create it if absent or extend it if present.
- [ ] 0.5 RECON: Read `lib/releaser/publisher.ex` lines 28–90. Confirm the silent dep-strip block is at lines 33–38 (the `publishable_names` / `publishable_apps_filtered` pattern). This block becomes dead code after Phase 2 and MUST be removed, not commented out.

---

## Phase 1 — Publisher.blocked_with_reasons/1 + blocked_names/1

All tasks in this phase touch:
- Test file: `test/releaser/publisher_test.exs`
- Implementation file: `lib/releaser/publisher.ex`

### 1A — Direct block scenario

- [ ] 1.1 RED: Add `describe "blocked_names/1"` block. Write test `"returns app with direct non-publishable dep"`. Fixture: `[%App{name: "csd", publish: true, deps: ["openssl"]}, %App{name: "openssl", publish: false, deps: []}]`. Assert `Publisher.blocked_names(apps) == MapSet.new(["csd"])`.
  - Spec scenario: "direct block — dep is non-publishable"
  - File: `test/releaser/publisher_test.exs`

- [ ] 1.2 GREEN: Add public `blocked_with_reasons/1` function to `lib/releaser/publisher.ex` with the iterative worklist algorithm (design §3). Add public `blocked_names/1` as thin wrapper: `Map.keys(reasons) |> MapSet.new()`. Test 1.1 must pass. No other tests may break.
  - Files: `lib/releaser/publisher.ex`

### 1B — Transitive block scenario

- [ ] 1.3 RED: Write test `"returns A and C when B is non-publishable (A→C→B transitive)"`. Fixture: `[%App{name: "a", publish: true, deps: ["c"]}, %App{name: "c", publish: true, deps: ["b"]}, %App{name: "b", publish: false, deps: []}]`. Assert `blocked_names(apps) == MapSet.new(["a", "c"])`.
  - Spec scenario: "transitive block A → C → B"
  - File: `test/releaser/publisher_test.exs`

- [ ] 1.4 GREEN: Verify iterative worklist already handles transitivity (round 1 adds "c", round 2 adds "a"). No implementation change needed if 1.2 was correct — confirm test passes. If not, fix the worklist loop in `lib/releaser/publisher.ex`.
  - File: `lib/releaser/publisher.ex`

### 1C — No blocking scenario

- [ ] 1.5 RED: Write test `"returns empty MapSet when all deps publishable"`. Fixture: all apps have `publish: true`, no cross-dep to non-publishable. Assert `blocked_names(apps) == MapSet.new()`.
  - Spec scenario: "no blocking"
  - File: `test/releaser/publisher_test.exs`

- [ ] 1.6 GREEN: Confirm no implementation change needed. Test must pass from 1.2's worklist.
  - File: `lib/releaser/publisher.ex`

### 1D — Standalone app scenario

- [ ] 1.7 RED: Write test `"returns empty MapSet for standalone publishable app with no deps"`. Fixture: `[%App{name: "safe", publish: true, deps: []}]`. Assert `blocked_names(apps) == MapSet.new()`.
  - Spec scenario: "app with no path deps"
  - File: `test/releaser/publisher_test.exs`

- [ ] 1.8 GREEN: Confirm test passes from 1.2's worklist.
  - File: `lib/releaser/publisher.ex`

### 1E — Cycle with non-publishable feeder

- [ ] 1.9 RED: Write test `"handles cycle among publishable apps and terminates"`. Fixture: `a → b → a` (cycle), `a → c` where `c.publish = false`. Assert `blocked_names(apps) == MapSet.new(["a", "b"])`. Assert the call terminates (no infinite loop — ExUnit timeout of 5s is sufficient).
  - Spec scenario: "cycle with one non-publishable feeder"
  - File: `test/releaser/publisher_test.exs`

- [ ] 1.10 GREEN: Confirm worklist terminates by fixed-point: blocked set is monotone-growing and bounded by app count. If 1.2's implementation is correct, test passes. If not, verify the `added_this_round` break condition in `lib/releaser/publisher.ex`.
  - File: `lib/releaser/publisher.ex`

### 1F — blocked_with_reasons/1 shape

- [ ] 1.11 RED: Write test `"blocked_with_reasons/1 returns map with immediate causes only"`. Fixture: `a → c → b (non-pub)`. Assert `blocked_with_reasons(apps) == %{"c" => ["b"], "a" => ["c"]}`. Confirms IMMEDIATE cause, not transitive root.
  - Spec scenario: "transitive immediate cause" (publisher spec §blocked_with_reasons shape)
  - File: `test/releaser/publisher_test.exs`

- [ ] 1.12 GREEN: Confirm implementation from 1.2 stores immediate blocking deps per app (`reasons` map in the worklist). Test must pass. If `reasons["a"]` incorrectly lists `"b"` instead of `"c"`, fix the blocking_deps collection loop in `lib/releaser/publisher.ex`.
  - File: `lib/releaser/publisher.ex`

---

## Phase 2 — Publisher.plan/1 integration

All tasks in this phase touch:
- Test file: `test/releaser/publisher_test.exs` (new `describe "plan/1 — blocking detection"` block)
- Implementation file: `lib/releaser/publisher.ex` (lines 33–38 removal + skipped construction)

> **GUARDRAIL**: The silent dep-strip at `lib/releaser/publisher.ex:36-38` MUST be removed entirely in task 2.2. It is not just dead code — leaving it produces confusing read-order for future developers. Remove it, do not comment it out.

> **GUARDRAIL**: Blocked check happens BEFORE Hex status check in `plan/1`. Task 2.10 tests this explicitly.

> **GUARDRAIL**: `blocked_by` field stores IMMEDIATE causes, not the transitive root. The `blocked_with_reasons/1` result already provides this correctly.

### 2A — Blocked app excluded from levels/apps

- [ ] 2.1 RED: Add `describe "plan/1 — blocking detection"` block. Write test `"omits blocked apps from levels and apps, emits :blocked_by_deps in skipped"`. Fixture: `csd (publish: true, deps: ["openssl"]), openssl (publish: false, deps: [])`. Mock Hex status for `csd` (or use `--skip-hex` if available). Assert: (a) `plan.apps` does not contain `csd`; (b) `plan.levels` does not contain `"csd"` in any level; (c) `plan.skipped` contains `%{app: "csd", reason: :blocked_by_deps, blocked_by: ["openssl"]}`.
  - Spec scenario: "plan/1 excludes blocked from levels/apps"
  - File: `test/releaser/publisher_test.exs`

- [ ] 2.2 GREEN: In `lib/releaser/publisher.ex`:
  1. REMOVE the silent dep-strip block (lines 33–38): `publishable_names = ...` / `publishable_apps_filtered = ...` and its `Enum.map`.
  2. ADD `blocked_reasons = blocked_with_reasons(publishable_apps)` and `blocked_set = blocked_reasons |> Map.keys() |> MapSet.new()`.
  3. ADD `{candidate_apps, blocked_apps} = Enum.split_with(...)` — blocked apps excluded.
  4. Replace all downstream references to `publishable_apps_filtered` with `candidate_apps`.
  5. Augment skipped entries construction: emit `blocked_skipped_entries` (one per `blocked_apps` entry) and prepend to `hex_skipped_entries` → `skipped_entries = blocked_skipped_entries ++ hex_skipped_entries`.
  - File: `lib/releaser/publisher.ex`

### 2B — Transitive immediate cause in skipped entry

- [ ] 2.3 RED: Write test `"plan/1 :blocked_by lists immediate dep, not transitive root"`. Fixture: `a → c (pub) → b (non-pub)`. Assert `plan.skipped` for `a` has `blocked_by: ["c"]`, not `["b"]`.
  - Spec scenario: "transitive immediate cause"
  - File: `test/releaser/publisher_test.exs`

- [ ] 2.4 GREEN: Verify 2.2's implementation correctly passes `Map.fetch!(blocked_reasons, app.name)` as `blocked_by`. No additional change if 1.11/1.12 confirmed immediate-cause semantics. Test must pass.
  - File: `lib/releaser/publisher.ex`

### 2C — Hex check skipped for blocked apps

- [ ] 2.5 RED: Write test `"plan/1 applies blocking before Hex status filtering"`. Fixture: `csd (blocked)` alongside `safe (publishable, already on Hex)`. Assert `csd` appears in `skipped` with `reason: :blocked_by_deps` (NOT `:already_published`) — i.e., Hex status is never checked for blocked apps.
  - Spec scenario: "Hex check skipped for blocked"
  - File: `test/releaser/publisher_test.exs`

- [ ] 2.6 GREEN: Verify 2.2's split (blocked apps exit before `compute_statuses` or are simply excluded from the Hex-filter split) is correct. Blocked apps must not appear in `hex_skipped`. Test must pass.
  - File: `lib/releaser/publisher.ex`

### 2D — --only filter post-blocking

- [ ] 2.7 RED: Write test `"plan/1 with --only filters after blocking removal"`. Fixture: `csd (blocked), safe (publishable), another (publishable)`. Call with `only: ["safe"]`. Assert: `plan.apps == ["safe"]` (or similar); `csd` still appears in `skipped` as `:blocked_by_deps`; `another` appears in `skipped` as `:not_selected` (or whatever the existing --only skip reason is).
  - Spec scenario: "--only filter post-blocking"
  - File: `test/releaser/publisher_test.exs`

- [ ] 2.8 GREEN: Verify that the `--only` filter in `plan/1` (existing logic at publisher.ex:73–82 per design) operates on `candidate_apps` (post-blocking), not on all publishable apps. No structural change needed if 2.2 threaded correctly. Test must pass.
  - File: `lib/releaser/publisher.ex`

### 2E — All-publishable workspace (no blocking)

- [ ] 2.9 RED: Write test `"plan/1 emits no :blocked_by_deps when no blocking exists"`. Fixture: all apps `publish: true`, no cross-dep to non-publishable. Assert `plan.skipped` contains no entry with `reason: :blocked_by_deps`.
  - Spec scenario: "all-publishable workspace"
  - File: `test/releaser/publisher_test.exs`

- [ ] 2.10 GREEN: Confirm test passes from 2.2's implementation — `blocked_apps` is empty, `blocked_skipped_entries` is `[]`.
  - File: `lib/releaser/publisher.ex`

---

## Phase 3 — Mix.Tasks.Releaser.Graph compact badge

All tasks in this phase touch:
- Test file: `test/mix/tasks/releaser_graph_test.exs`
- Implementation file: `lib/mix/tasks/releaser.graph.ex`

> **GUARDRAIL**: The existing test at `test/mix/tasks/releaser_graph_test.exs:85` currently asserts `[publish: ✓]` for `csd`. This encodes the BUG being fixed. Task 3.1 intentionally inverts it to assert `[publish: ✗ blocked]`. This is NOT a regression — add an explicit comment in the test: `# intentionally inverted — see proposal.md §7 backwards-compatibility`. Same applies to line 97 (task 3.3).

> **GUARDRAIL**: `Publisher.blocked_with_reasons/1` (and `blocked_names/1`) MUST be called exactly ONCE inside `render_graph/2`, not inside `render_app_compact` or `render_app_detailed`. The single computed value is threaded downward. This is a structural constraint; task 3.6 enforces it.

### 3A — Invert existing csd compact badge test (line 85)

- [ ] 3.1 RED: At `test/mix/tasks/releaser_graph_test.exs:85`, change assertion from `assert output =~ "csd v2.0.0 [publish: ✓]"` to `assert output =~ "csd v2.0.0 [publish: ✗ blocked]"`. This test is now RED (implementation not yet updated). Add comment: `# intentional inversion — csd is blocked by openssl (non-publishable); see design.md §8`.
  - Spec scenario: "compact badge — blocked state"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 3.2 GREEN: In `lib/mix/tasks/releaser.graph.ex`:
  1. Add `Publisher` to the alias list (line ~56).
  2. In `render_graph/2`, after computing `levels` and `graph`, add: `blocked_reasons = Publisher.blocked_with_reasons(apps)` and `blocked_names = blocked_reasons |> Map.keys() |> MapSet.new()`.
  3. Thread `blocked_reasons` and `blocked_names` into `render_app_compact/8` (extend arity from 6 to 8).
  4. In `compact_badges/4` (extend from 3), pass `blocked? = MapSet.member?(blocked_names, app.name)` to `publish_badge_compact/2` (extend from 1 to 2).
  5. Add three clauses to `publish_badge_compact/2`: `(true, true)` → `UI.red("[publish: ✗ blocked]")`; `(true, false)` → `UI.green("[publish: ✓]")`; `(_, _)` → `UI.dim("[publish: ✗]")`.
  6. Remove or replace old single-boolean `publish_badge_compact/1` clauses.
  - File: `lib/mix/tasks/releaser.graph.ex`

### 3B — Invert existing csd compact + attribute form test (line 97)

- [ ] 3.3 RED: At `test/mix/tasks/releaser_graph_test.exs:97`, change assertion from `assert output =~ "csd v2.0.0 [publish: ✓] [@version]"` to `assert output =~ "csd v2.0.0 [publish: ✗ blocked] [@version]"`. Add comment: `# intentional inversion — see design.md §8`.
  - Spec scenario: "compact badge — blocked state with @version attribute"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 3.4 GREEN: Confirm test 3.3 passes from implementation in 3.2 — the `[@version]` attribute suffix is appended after the badge string; no structural change needed.
  - File: `lib/mix/tasks/releaser.graph.ex`

### 3C — New: openssl still shows [publish: ✗] (unchanged, not "blocked")

- [ ] 3.5 RED: Write NEW test `"non-publishable app shows [publish: ✗] without 'blocked' word"`. Use the existing rich-apps fixture (openssl, publish: false). Assert `output =~ "openssl"` and `output =~ "[publish: ✗]"` and `refute output =~ "openssl.*blocked"`. Confirms third clause of `publish_badge_compact/2`.
  - Spec scenario: "non-publishable shows [publish: ✗] (no 'blocked' word)"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 3.6 GREEN: Confirm third clause `publish_badge_compact(_, _)` returns `UI.dim("[publish: ✗]")` (no "blocked" word). Test passes from 3.2.
  - File: `lib/mix/tasks/releaser.graph.ex`

### 3D — New: safe publishable app shows [publish: ✓]

- [ ] 3.7 RED: Write NEW test `"safe publishable app with no deps shows [publish: ✓]"`. Fixture: `@safe_apps = [%App{name: "safe", publish: true, version: "1.0.0", deps: []}]`. Call `render_graph/2` (fixture-only, no Workspace.discover). Assert `output =~ "safe"` and `output =~ "[publish: ✓]"` and `refute output =~ "blocked"`.
  - Spec scenario: "safe publishable app shows [publish: ✓]"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 3.8 GREEN: Confirm second clause `publish_badge_compact(true, false)` returns `UI.green("[publish: ✓]")`. Test passes from 3.2. This also confirms `blocked_names` is an empty MapSet for a fully publishable fixture.
  - File: `lib/mix/tasks/releaser.graph.ex`

---

## Phase 4 — Mix.Tasks.Releaser.Graph detailed line

All tasks touch:
- Test file: `test/mix/tasks/releaser_graph_test.exs`
- Implementation file: `lib/mix/tasks/releaser.graph.ex`

> **GUARDRAIL**: The existing test at `test/mix/tasks/releaser_graph_test.exs:131-132` currently asserts `publish: yes` for csd. Task 4.1 intentionally inverts it to `publish: blocked (needs: openssl)`. Add comment: `# intentional inversion — see design.md §8`.

### 4A — Invert existing detailed "publish: yes" for csd (lines 131-132)

- [ ] 4.1 RED: At `test/mix/tasks/releaser_graph_test.exs:131-132`, change assertion from `assert output =~ "publish: yes"` (for csd) to `assert output =~ "publish: blocked (needs: openssl)"`. Add comment: `# intentional inversion — csd blocked by openssl; see design.md §8`.
  - Spec scenario: "blocked app in detailed mode"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 4.2 GREEN: In `lib/mix/tasks/releaser.graph.ex`:
  1. Extend `render_app_detailed/8` signature (from 6 to 8 args, matching compact).
  2. Add three clauses to `publish_text_detailed/2` (extend from 1-arg to 2-arg): `(true, [_|_] = blocked_by)` → `UI.red("blocked") <> UI.dim(" (needs: #{Enum.join(blocked_by, ", ")})")`.  `(true, _)` → `UI.green("yes")`. `(_, _)` → `UI.dim("no")`.
  3. In `render_app_detailed`, pass `Map.get(blocked_reasons, app.name, [])` as the second arg to `publish_text_detailed`.
  - File: `lib/mix/tasks/releaser.graph.ex`

### 4B — New: non-blocked publishable shows "publish: yes" in detailed mode

- [ ] 4.3 RED: Write NEW test `"safe publishable app shows 'publish: yes' in detailed mode"`. Use `@safe_apps` fixture, call with `detailed: true`. Assert `output =~ "publish: yes"` and `refute output =~ "blocked"`.
  - Spec scenario: "non-blocked publishable in detailed mode"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 4.4 GREEN: Confirm second clause `publish_text_detailed(true, _no_block)` returns `UI.green("yes")`. Test passes from 4.2.
  - File: `lib/mix/tasks/releaser.graph.ex`

### 4C — New: blocked app shows correct detailed line with dep names

- [ ] 4.5 RED: Write NEW test `"blocked app shows 'publish: blocked (needs: openssl)' in detailed mode"`. Use rich-apps fixture (csd → openssl). Assert `output =~ "publish: blocked (needs: openssl)"`.
  - Spec scenario: "blocked app in detailed mode with dep names"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 4.6 GREEN: Confirm first clause `publish_text_detailed(true, ["openssl"])` produces the correct string. Test passes from 4.2.
  - File: `lib/mix/tasks/releaser.graph.ex`

---

## Phase 5 — Mix.Tasks.Releaser.Graph summary

All tasks touch:
- Test file: `test/mix/tasks/releaser_graph_test.exs`
- Implementation file: `lib/mix/tasks/releaser.graph.ex`

> **GUARDRAIL**: The existing test at `test/mix/tasks/releaser_graph_test.exs:181` asserts `"Publishable apps:    1"`. After this change, csd is blocked, so the count drops to 0. Task 5.1 intentionally inverts this. Add a NEW assertion for `"Blocked apps:        1"`. Add comment: `# intentional inversion — see design.md §8`.

### 5A — Invert existing summary "Publishable apps: 1" (line 181)

- [ ] 5.1 RED: At `test/mix/tasks/releaser_graph_test.exs:177-183`, change `assert output =~ "Publishable apps:    1"` to `assert output =~ "Publishable apps:    0"`. Add NEW assertion: `assert output =~ "Blocked apps:        1"`. Add comment: `# intentional inversion — csd now blocked; see design.md §8`.
  - Spec scenario: "summary subtracts blocked; Blocked apps line appears"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 5.2 GREEN: In `lib/mix/tasks/releaser.graph.ex` summary block (lines 147–156 per design):
  1. Rename `publishable` local to `publishable_total = Enum.count(apps, & &1.publish)`.
  2. Add `blocked_count = MapSet.size(blocked_names)`.
  3. Compute `publishable = publishable_total - blocked_count`.
  4. Add conditional: `if blocked_count > 0, do: UI.info("  Blocked apps:        #{blocked_count}")`.
  5. Position "Blocked apps:" BETWEEN "Publishable apps:" and "Publish order:" (column-aligned: 23 chars pre-value).
  - File: `lib/mix/tasks/releaser.graph.ex`

### 5B — No blocked apps — "Blocked apps:" line absent

- [ ] 5.3 RED: Write NEW test `"summary omits 'Blocked apps:' line when no apps are blocked"`. Use `@safe_apps` fixture (all publishable, no deps). Assert `output =~ "Publishable apps:    1"` and `refute output =~ "Blocked apps:"`.
  - Spec scenario: "no blocked apps — Blocked line absent"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 5.4 GREEN: Confirm the `if blocked_count > 0` guard from 5.2 suppresses the line for a zero-blocked fixture. Test passes.
  - File: `lib/mix/tasks/releaser.graph.ex`

### 5C — Mixed fixture: one blocked out of two publishable

- [ ] 5.5 RED: Write NEW test `"summary shows Publishable apps: 1 and Blocked apps: 1 with mixed fixture"`. Fixture: `csd (blocked by openssl), safe (pub, no deps), openssl (non-pub)`. Assert `output =~ "Publishable apps:    1"` (safe only) and `output =~ "Blocked apps:        1"`.
  - Spec scenario: "one blocked out of two publishable — summary"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 5.6 GREEN: Confirm counts are correct: `publishable_total = 2` (csd+safe), `blocked_count = 1` (csd), `publishable = 1`. Test passes from 5.2.
  - File: `lib/mix/tasks/releaser.graph.ex`

### 5D — All publishable apps blocked

- [ ] 5.7 RED: Write NEW test `"summary shows Publishable apps: 0 and Blocked apps: N when all publishable apps are blocked"`. Fixture: all publishable apps have non-publishable dep. Assert `output =~ "Publishable apps:    0"` and `output =~ "Blocked apps:        N"`.
  - Spec scenario: "all publishable apps blocked"
  - File: `test/mix/tasks/releaser_graph_test.exs`

- [ ] 5.8 GREEN: Confirm test passes from 5.2 — `publishable = publishable_total - blocked_count = 0`.
  - File: `lib/mix/tasks/releaser.graph.ex`

---

## Phase 6 — Mix.Tasks.Releaser.Publish skipped renderer branch

All tasks touch:
- Test file: `test/mix/tasks/releaser_publish_test.exs` (CREATE if absent)
- Implementation file: `lib/mix/tasks/releaser.publish.ex`

> **DECISION**: Phase 0 task 0.4 confirms whether `test/mix/tasks/releaser_publish_test.exs` exists. If it does NOT exist, task 6.1 creates it using `Mix.Shell.Process` capture — the same pattern as `releaser_graph_test.exs`. If it exists, task 6.1 adds a new `describe` block.

### 6A — Create test file (if absent) and write dry-run blocked app test

- [ ] 6.1 RED: Create `test/mix/tasks/releaser_publish_test.exs` (if absent). Write test `"skipped section shows blocked app with non-publishable deps named"`. Use `Mix.Shell.Process` to capture output. Inject a `plan/1` result stub with `skipped: [%{app: "csd", local: "2.0.0", hex: nil, reason: :blocked_by_deps, blocked_by: ["openssl"]}]`. Assert `output =~ "csd"`, `output =~ "blocked"`, and `output =~ "openssl"`.
  - Spec scenario: "dry-run with one blocked app"
  - File: `test/mix/tasks/releaser_publish_test.exs`

- [ ] 6.2 GREEN: In `lib/mix/tasks/releaser.publish.ex` (skipped renderer, lines 48–65 per design):
  1. Change `Enum.each(skipped, fn %{app: name, local: local, hex: hex, reason: reason} -> ...`)  to also pattern-match or capture `entry` for the new branch.
  2. Add third `case` arm:
     ```elixir
     :blocked_by_deps ->
       deps_list = Map.get(entry, :blocked_by, []) |> Enum.join(", ")
       "blocked by non-publishable deps: #{deps_list}"
     ```
  3. The rendered line: `"  #{name}  — #{label}"` — consistent with existing branches.
  - File: `lib/mix/tasks/releaser.publish.ex`

### 6B — Blocked alongside already-published

- [ ] 6.3 RED: Write NEW test `"skipped section renders both :blocked_by_deps and :already_published reasons distinctly"`. Skipped list contains both a blocked entry and an already-published entry. Assert both lines appear and the blocked line contains "blocked" + dep names; already-published line contains "already on Hex".
  - Spec scenario: "blocked alongside already-published"
  - File: `test/mix/tasks/releaser_publish_test.exs`

- [ ] 6.4 GREEN: Confirm `case reason do` with three arms handles both reasons independently. Test passes from 6.2.
  - File: `lib/mix/tasks/releaser.publish.ex`

---

## Phase 7 — Verification

- [ ] 7.1 VERIFY: Run `mix test`. Confirm 0 failures, 0 errors. All new tests pass. All pre-existing tests (excluding intentionally inverted ones that were already updated) pass.

- [ ] 7.2 AUDIT: Read `test/mix/tasks/releaser_graph_test.exs` lines 85, 97, 131-132, 181 and confirm each has been updated AND carries the `# intentional inversion` comment. No "old behavior" assertion must survive. Any survivor is a bug — fix before merging.

- [ ] 7.3 AUDIT: Read `lib/releaser/publisher.ex` lines 33–38 and confirm the silent dep-strip block (`publishable_names` / `publishable_apps_filtered`) is GONE. The refactored code must use `candidate_apps` and `blocked_set` in its place.

- [ ] 7.4 AUDIT: Confirm `Publisher.blocked_with_reasons/1` is called exactly once in `render_graph/2` (in `lib/mix/tasks/releaser.graph.ex`), not inside `render_app_compact` or `render_app_detailed`. Read the function body to verify. No redundant calls.

---

## Phase 8 — Documentation

- [ ] 8.1 DOC: Update `@moduledoc` in `lib/mix/tasks/releaser.graph.ex` to describe the three publish badge states (dim `[publish: ✗]`, green `[publish: ✓]`, red `[publish: ✗ blocked]`) and the conditional "Blocked apps:" summary line.

- [ ] 8.2 DOC: Update `@moduledoc` in `lib/releaser/publisher.ex` to describe the two new public functions (`blocked_names/1`, `blocked_with_reasons/1`) and summarize the iterative worklist algorithm (O(apps²) worst case, bounded by app count, terminates on cycles).

---

## Parallel vs. Sequential map

```
Phase 0 (recon) → sequential prerequisite

Phase 1 (blocked_names) → sequential prerequisite for Phase 2
  Tasks 1.1→1.2 (direct block)
  Tasks 1.3→1.4 (transitive) — can start once 1.2 GREEN
  Tasks 1.5→1.6 (no blocking) — can start once 1.2 GREEN
  Tasks 1.7→1.8 (standalone) — can start once 1.2 GREEN
  Tasks 1.9→1.10 (cycle) — can start once 1.2 GREEN
  Tasks 1.11→1.12 (reasons shape) — can start once 1.2 GREEN
  [1.3–1.12 pairs are independent of each other; run in parallel]

Phase 2 (plan/1) → starts after Phase 1 completes
  Tasks 2.1→2.2 (basic exclusion + removal of dep-strip) — first; others depend
  Tasks 2.3→2.4, 2.5→2.6, 2.7→2.8, 2.9→2.10 — parallel after 2.2

Phase 3 (compact badge) → starts after Phase 2 completes
  Tasks 3.1→3.2 (core implementation) — first
  Tasks 3.3→3.4, 3.5→3.6, 3.7→3.8 — parallel after 3.2

Phase 4 (detailed line) → can start in parallel with Phase 3 after Phase 2, BUT
  3.2 must complete first (signature changes in render_graph/2 affect detailed too)
  Tasks 4.1→4.2 (core), 4.3→4.4, 4.5→4.6 — sequential then parallel

Phase 5 (summary) → can start in parallel with Phase 4 after 3.2
  Tasks 5.1→5.2 (core), 5.3→5.4, 5.5→5.6, 5.7→5.8 — sequential then parallel

Phase 6 (publish task) → fully independent after Phase 2
  Tasks 6.1→6.2 (core), 6.3→6.4 — sequential

Phase 7 (verify) → after ALL phases complete; sequential

Phase 8 (docs) → after Phase 7; parallel (8.1 and 8.2 independent)
```

---

## Critical guardrail summary (apply phase reference)

| # | Guardrail | Location |
|---|-----------|----------|
| G1 | Lines 85, 97, 131-132, 181 in `releaser_graph_test.exs` are INTENTIONAL inversions. Must be updated, not preserved. Add `# intentional inversion` comment to each. | Phases 3, 4, 5 |
| G2 | Silent dep-strip at `publisher.ex:33-38` MUST be removed entirely — not commented out. | Phase 2, task 2.2 |
| G3 | `Publisher.blocked_with_reasons/1` (and derived `blocked_names`) called ONCE in `render_graph/2`, threaded downward. Not called inside per-app renderers. | Phase 3, task 3.2 |
| G4 | Blocked check happens BEFORE Hex status check in `plan/1`. | Phase 2, task 2.5/2.6 |
| G5 | `blocked_by` field stores IMMEDIATE causes, not transitive root. | Phase 2, task 2.3/2.4 and Phase 1, task 1.11/1.12 |
| G6 | New module-level dependency `Mix.Tasks.Releaser.Graph → Releaser.Publisher` is approved. Add `Publisher` to alias list. | Phase 3, task 3.2 |
| G7 | `test/mix/tasks/releaser_publish_test.exs` — create if absent; use `Mix.Shell.Process` capture pattern matching `releaser_graph_test.exs`. | Phase 6, task 6.1 |
