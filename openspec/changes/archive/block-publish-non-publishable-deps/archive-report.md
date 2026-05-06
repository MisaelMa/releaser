# Archive Report: block-publish-non-publishable-deps

**Date**: 2026-05-04  
**Change**: block-publish-non-publishable-deps  
**Status**: ARCHIVED

---

## Intent

Stop releaser from publishing apps whose dependency closure contains non-publishable apps (`publish: false`), and surface that fact clearly in `mix releaser.graph` and `mix releaser.publish`. When app A (publish: true) depends — directly or transitively — on app B (publish: false), A is "blocked": releaser must skip it and tell the user why, naming the offending dep(s). Previously, `Publisher.plan/1` silently stripped non-publishable names from each publishable app's `:deps`, producing broken Hex packages with structurally incomplete dependencies.

---

## Verification Verdict

**PASS WITH WARNINGS RESOLVED**

- **Tests**: 207 passed / 0 failed
- **Build**: Clean with `--warnings-as-errors`
- **Tasks**: 54 total, all marked [x] (both warnings closed by orchestrator)
  - W1 (tasks.md checkboxes): ✅ RESOLVED — all 54 tasks now [x]
  - W2 (--only filter test): ✅ RESOLVED — new test added in Phase 2

---

## Files Modified in Production Code

| File | Changes |
|------|---------|
| `lib/releaser/publisher.ex` | ADDED `blocked_names/1` (public); ADDED `blocked_with_reasons/1` (public); ADDED `do_blocked/4` (private worklist); REMOVED silent dep-strip (lines 32-38); MODIFIED `plan/1` to compute blocking before Hex filter; UPDATED moduledoc |
| `lib/mix/tasks/releaser.graph.ex` | ADDED Publisher alias; MODIFIED `render_graph/2` to compute `blocked_reasons` once; EXTENDED `render_app_compact`, `render_app_detailed`, `compact_badges` arities; REPLACED `publish_badge_compact/1` with 3-clause `publish_badge_compact/2`; REPLACED `publish_text_detailed/1` with 3-clause `publish_text_detailed/3`; MODIFIED summary: subtract blocked from publishable, conditional "Blocked apps:" line; UPDATED moduledoc |
| `lib/mix/tasks/releaser.publish.ex` | EXTRACTED `render_skipped/1` as public; ADDED `:blocked_by_deps` branch in skipped renderer |

---

## Files Modified in Tests

| File | Changes |
|------|---------|
| `test/releaser/publisher_test.exs` | ADDED 10 tests for `blocked_names/1` and `blocked_with_reasons/1`; ADDED 5 tests for `plan/1` blocking integration |
| `test/mix/tasks/releaser_graph_test.exs` | INVERTED 4 existing tests (lines 85, 97, 131-132, 181) encoding the old bug; ADDED 7 new tests for blocked badge states and summary; UPDATED with `# intentional inversion` comments |
| `test/mix/tasks/releaser_publish_test.exs` | CREATED (new file); ADDED 5 tests for `:blocked_by_deps` rendering |

---

## New Public APIs

| Module | Function | Signature | Purpose |
|--------|----------|-----------|---------|
| `Releaser.Publisher` | `blocked_names/1` | `[%App{}] -> MapSet.t(String.t())` | Returns set of apps blocked by non-publishable deps (iterative worklist, cycle-safe) |
| `Releaser.Publisher` | `blocked_with_reasons/1` | `[%App{}] -> %{String.t() => [String.t()]}` | Returns map of blocked app names to their immediate blocking dep names |
| `Mix.Tasks.Releaser.Publish` | `render_skipped/1` | `[%{app: String.t(), ...}] -> :ok` | Public extraction of skipped-entry renderer (supports new `:blocked_by_deps` reason) |

---

## Behavior Changes

1. **Graph compact badge**: Three states now rendered:
   - `[publish: ✗]` (dim) — app has `publish: false` (unchanged)
   - `[publish: ✓]` (green) — app has `publish: true` AND not blocked (unchanged)
   - `[publish: ✗ blocked]` (red) — app has `publish: true` BUT blocked by non-publishable deps (NEW)

2. **Graph detailed line**: Three states now rendered:
   - `publish: no` (dim) — app has `publish: false` (unchanged)
   - `publish: yes` (green) — app has `publish: true` AND not blocked (unchanged)
   - `publish: blocked (needs: <deps>)` (red) — app has `publish: true` BUT blocked by the named non-publishable deps (NEW)

3. **Graph summary**:
   - "Publishable apps:" count NOW EXCLUDES blocked apps (was: included them)
   - NEW conditional line: "Blocked apps: N" appears when N > 0 (absent when 0)

4. **mix releaser.publish skipped section**:
   - NEW reason `:blocked_by_deps` rendered as: `~ <app>  — blocked by non-publishable deps: <names>`
   - Existing `:already_published` and `:prerelease` rendering unchanged

5. **Publisher.plan/1 skipped entries**:
   - NEW reason value `:blocked_by_deps`
   - NEW key `blocked_by: [String.t()]` (IMMEDIATE blocking dep names, not transitive root)
   - Silent dep-strip removed: blocked apps now surface explicitly in `skipped`, non-blocked apps keep full `.deps`

---

## Test Inversions (Intentional)

Four existing tests in `test/mix/tasks/releaser_graph_test.exs` were intentionally flipped because they encoded the bug:

| Line(s) | Test | Old Assertion | New Assertion | Reason |
|---------|------|---------------|---------------|--------|
| 85 | compact badge for csd (blocked by openssl) | `[publish: ✓]` | `[publish: ✗ blocked]` | csd was publishing as safe; now correctly blocked |
| 97 | compact badge with @version attribute | `[publish: ✓] [@version]` | `[publish: ✗ blocked] [@version]` | same, with attribute suffix |
| 131-132 | detailed line for csd | `publish: yes` | `publish: blocked (needs: openssl)` | detailed mode now shows blocked state |
| 181 | summary publishable count | `Publishable apps: 1` | `Publishable apps: 0`; + NEW `Blocked apps: 1` | csd blocked; safe remains only publishable |

All four locations carry explicit `# intentional inversion` comments.

---

## Spec Deltas Merged into Main Specs

| Main Spec File | Action | Details |
|----------------|--------|---------|
| `openspec/specs/publisher.md` | CREATED | New spec file for `Releaser.Publisher` module; added 3 capability sections: `blocked_names/1` (5 scenarios), `blocked_with_reasons/1` (2 scenarios), `plan/1` (5 scenarios). Total 12 scenarios. |
| `openspec/specs/mix-tasks.md` | UPDATED | Merged 4 new capability sections for blocking detection: compact badge (4 scenarios), detailed line (2 scenarios), summary (3 scenarios), and updated scenario numbering from 5-6 to 7-9. Total 9 new scenarios added. |
| `openspec/specs/mix-tasks-publish.md` | CREATED | New spec file for `Mix.Tasks.Releaser.Publish` module; added 1 capability section: `:blocked_by_deps` rendering (2 scenarios). Total 2 scenarios. |

---

## Observation IDs for Traceability

| Artifact | Engram Observation ID | Date |
|----------|----------------------|------|
| Proposal | #46 | 2026-05-04 21:43:03 |
| Spec (delta) | #47 | 2026-05-04 23:30:00 |
| Design | #50 | 2026-05-05 02:38:50 |
| Tasks | #51 | 2026-05-05 02:42:59 |
| Verify Report | #59 | 2026-05-05 03:20:33 |
| Archive Report | This report | 2026-05-05 (archived) |

---

## Suggested Conventional Commit

```
feat(releaser): block publish on non-publishable deps

mix releaser.graph now shows [publish: ✗ blocked] for apps whose internal
deps include non-publishable apps. Publisher.plan/1 excludes those apps
from the publish plan and surfaces them in skipped with reason
:blocked_by_deps and the immediate blocking dep names.

Removes the silent dep-strip in Publisher.plan/1 that previously
published packages with non-publishable deps quietly removed —
producing broken Hex packages.

- Added Publisher.blocked_names/1 (public, O(apps²) iterative worklist)
- Added Publisher.blocked_with_reasons/1 (public, immediate-cause semantics)
- Modified Publisher.plan/1 to emit :blocked_by_deps skipped entries with
  blocked_by: [...] field (immediate deps, not transitive root)
- Modified Mix.Tasks.Releaser.Graph badge rendering: three states for
  publish (dim, green, red blocked)
- Modified Mix.Tasks.Releaser.Graph detailed line: three states for publish
- Modified Mix.Tasks.Releaser.Graph summary: subtract blocked from
  publishable, conditional "Blocked apps: N" line
- Extracted Mix.Tasks.Releaser.Publish.render_skipped/1 as public
- Added :blocked_by_deps renderer in Mix.Tasks.Releaser.Publish

Tests: 207 passed. Four existing graph tests intentionally inverted (they
encoded the bug we are fixing). All tests updated with comments.

Closes: (issue tracking non-publishable deps)
```

---

## Follow-Up Notes

None. Change is complete and ready for git commit. No architectural debt or outstanding scenarios.

---

## Closing Remarks

This change fixes a critical correctness bug: releaser was publishing Hex packages with incomplete dependency lists when those packages depended (directly or transitively) on non-publishable internal apps. The fix is comprehensive: detection, exclusion, visibility (badges + summary + publish renderer), and test inversions. The worklist algorithm handles cycles, the immediate-cause semantics match what users see in their own `mix.exs`, and the UI changes make the problem visible so users can act on it (reorganize deps or mark the app non-publishable). All 54 tasks complete, 207 tests passing, 0 failures.
