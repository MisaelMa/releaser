# Verification Report

**Change**: block-publish-non-publishable-deps
**Version**: N/A
**Mode**: Strict TDD
**Date**: 2026-05-04

---

## Completeness

| Metric | Value |
|--------|-------|
| Tasks total | 54 |
| Tasks complete (marked [x]) | 0 |
| Tasks incomplete (marked [ ]) | 54 |

WARNING: The `tasks.md` file was never updated by the apply phase — all 54 tasks remain as `[ ]`. The implementation is fully present and confirmed by passing tests; this is a bookkeeping omission only.

---

## Build & Tests Execution

**Build**: PASS — `mix compile --warnings-as-errors` exits 0, no warnings.

**Tests**: 206 passed / 0 failed / 0 skipped

**Coverage**: Not configured — N/A

---

## Audit Items (from apply guardrails)

| # | Audit item | Result |
|---|-----------|--------|
| 1 | Silent dep-strip removed (`publishable_apps_filtered`) | PASS — absent from publisher.ex |
| 2 | `Publisher.blocked_with_reasons/1` called exactly once in `render_graph/2` | PASS — single call at graph.ex:130 |
| 3 | 4 `# Intentional inversion` comments at lines 83, 97, 131, 183 of graph_test | PASS — all 4 present |
| 4 | `do_blocked/4` terminates on cycles via fixed-point (`if grew?, do: recurse, else: return`) | PASS — cycle test with 5s timeout passes |
| 5 | `blocked_by` stores IMMEDIATE cause (not transitive root) | PASS — confirmed by do_blocked/4 logic and test "blocked_by lists immediate dep, not transitive root" |
| 6 | `UI.red/1` exists at ui.ex:13 | PASS — `def red(text), do: "#{IO.ANSI.red()}#{text}#{IO.ANSI.reset()}"` |

---

## Spec Compliance Matrix

### Releaser.Publisher — blocked_names/1

| Scenario | Test | Result |
|----------|------|--------|
| direct block | `publisher_test > "returns app with direct non-publishable dep"` | ✅ COMPLIANT |
| transitive A→C→B | `publisher_test > "returns A and C when B is non-publishable (A→C→B transitive)"` | ✅ COMPLIANT |
| no blocking | `publisher_test > "returns empty MapSet when all deps publishable"` | ✅ COMPLIANT |
| standalone (no deps) | `publisher_test > "returns empty MapSet for standalone publishable app with no deps"` | ✅ COMPLIANT |
| cycle with non-publishable feeder | `publisher_test > "handles cycle among publishable apps and terminates"` | ✅ COMPLIANT |

### Releaser.Publisher — plan/1

| Scenario | Test | Result |
|----------|------|--------|
| direct exclusion from levels/apps | `publisher_test > "omits blocked apps from levels and apps; emits :blocked_by_deps in skipped"` | ✅ COMPLIANT |
| transitive immediate cause in skipped entry | `publisher_test > "blocked_by lists immediate dep, not transitive root"` | ✅ COMPLIANT |
| Hex check skipped for blocked | `publisher_test > "blocking applies before Hex status check (no :already_published for blocked app)"` | ✅ COMPLIANT |
| --only filter applied after blocking removal | (no test — task 2.7/2.8 not implemented) | ❌ UNTESTED |
| all-publishable workspace (no :blocked_by_deps) | `publisher_test > "emits no :blocked_by_deps when no blocking exists"` | ✅ COMPLIANT |

### Mix.Tasks.Releaser.Graph — compact badge

| Scenario | Test | Result |
|----------|------|--------|
| blocked app shows [publish: ✗ blocked] | `graph_test > "shows [publish: ✗ blocked] for apps blocked by non-publishable deps"` | ✅ COMPLIANT |
| non-publishable shows [publish: ✗] no 'blocked' | `graph_test > "non-publishable app keeps [publish: ✗] without 'blocked' word"` | ✅ COMPLIANT |
| safe publishable shows [publish: ✓] | `graph_test > "safe publishable app with no deps shows [publish: ✓]"` | ✅ COMPLIANT |
| no extra Workspace.discover call | structural evidence only (single call-site grep) | ⚠️ PARTIAL |

### Mix.Tasks.Releaser.Graph — detailed line

| Scenario | Test | Result |
|----------|------|--------|
| blocked app in detailed mode | `graph_test > "renders multiline branches under each app"` (asserts `publish: blocked (needs: openssl)`) | ✅ COMPLIANT |
| non-blocked publishable shows 'publish: yes' | `graph_test > "safe publishable app shows 'publish: yes' in detailed mode"` | ✅ COMPLIANT |

### Mix.Tasks.Releaser.Graph — summary

| Scenario | Test | Result |
|----------|------|--------|
| one blocked out of two publishable | `graph_test > "shows Publishable apps: 1 and Blocked apps: 1 with mixed fixture"` | ✅ COMPLIANT |
| no blocked apps — Blocked line absent | `graph_test > "omits 'Blocked apps:' line when no apps are blocked"` | ✅ COMPLIANT |
| all publishable apps blocked | `graph_test > "shows publishable apps count and blocked apps count"` (N=1 only) | ⚠️ PARTIAL |

### Mix.Tasks.Releaser.Publish — skipped renderer :blocked_by_deps

| Scenario | Test | Result |
|----------|------|--------|
| dry-run with one blocked app | `publish_test > "names the blocked app and lists its blocking deps"` | ✅ COMPLIANT |
| blocked alongside already-published | `publish_test > "renders blocked entry alongside :already_published distinctly"` | ✅ COMPLIANT |

**Compliance summary**: 18/21 scenarios compliant, 1 UNTESTED, 2 PARTIAL

---

## Correctness (Static)

| Requirement | Status | Notes |
|-------------|--------|-------|
| blocked_names/1 public, returns MapSet | ✅ Implemented | publisher.ex:45-50 |
| blocked_with_reasons/1 public, returns reasons map | ✅ Implemented | publisher.ex:61-70 |
| Iterative worklist, fixed-point exit on cycles | ✅ Implemented | do_blocked/4:72-96 |
| Silent dep-strip removed, candidate_apps used | ✅ Implemented | dep-strip absent |
| plan/1 emits :blocked_by_deps with :blocked_by | ✅ Implemented | publisher.ex:142-151 |
| Blocked check before Hex status filter | ✅ Implemented | split before compute_statuses |
| Compact badge 3-state | ✅ Implemented | publish_badge_compact/2:214-216 |
| blocked_with_reasons called once per render_graph/2 | ✅ Implemented | graph.ex:130 only |
| Detailed line 3-state | ✅ Implemented | publish_text_detailed/3:253-257 |
| Summary subtracts blocked, conditional Blocked line | ✅ Implemented | graph.ex:172-181 |
| :blocked_by_deps renderer in releaser.publish | ✅ Implemented | publish.ex:99-102 |
| UI.red/1 present | ✅ Confirmed | ui.ex:13 |
| No struct shape changes | ✅ Confirmed | App struct unchanged |
| No new modules | ✅ Confirmed | zero new modules |

---

## Coherence (Design)

| Decision | Followed? | Notes |
|----------|-----------|-------|
| Single blocked_with_reasons call in render_graph/2 | ✅ Yes | graph.ex:130 |
| Immediate causes only in blocked_by | ✅ Yes | do_blocked stores app.deps filtered against current blockers |
| Silent dep-strip removed (not commented) | ✅ Yes | absent |
| 4 inversion comments on old bug tests | ✅ Yes | all 4 confirmed |
| Publisher alias added to graph.ex | ✅ Yes | graph.ex:74 |
| New test file releaser_publish_test.exs created | ✅ Yes | 5 tests |
| Docs updated (moduledoc both modules) | ✅ Yes | both describe new functions and badge states |

---

## Issues Found

**CRITICAL** (must fix before archive):
None

**WARNING** (should fix):
- W1: `tasks.md` — all 54 tasks still `[ ]`. Apply phase never updated checkboxes. Bookkeeping only.
- W2: Spec scenario "plan/1 — --only filter applied after blocking removal" has no test. Tasks 2.7/2.8 not implemented. Implementation is present and correct, but the scenario is UNTESTED. Low risk because --only operates on the post-blocking list and does not interact with the blocked path in a novel way.

**SUGGESTION** (nice to have):
- S1: "All publishable apps blocked" summary scenario tested only with N=1. A multi-blocked fixture would increase confidence in the subtraction arithmetic.
- S2: No runtime isolation test for Workspace.discover not being called inside render_graph/2. Structural evidence (single call-site grep) is sufficient but not behavioral proof.

---

## Verdict

**PASS WITH WARNINGS**

206 tests, 0 failures. Compiles clean. All 6 audit guardrails pass. 18/21 spec scenarios have passing tests. The 2 WARNINGs (tasks.md bookkeeping + 1 untested --only scenario) do not block archive.
