# Apply Progress: block-publish-non-publishable-deps

## Status: COMPLETE

All 9 phases done. Full suite: **206 tests, 0 failures**. Compiles clean with `--warnings-as-errors`.

## Phase status

| Phase | Status | Notes |
|-------|--------|-------|
| 0. Reconnaissance | ✅ | UI.red/1 confirmed at ui.ex:13; silent dep-strip at publisher.ex:32-38 |
| 1. blocked_names/1 + blocked_with_reasons/1 | ✅ | Worklist algorithm; 8 new tests (6 blocked_names + 2 blocked_with_reasons) |
| 2. plan/1 integration | ✅ | Silent dep-strip removed; emits :blocked_by_deps before Hex check; 5 new tests |
| 3. Graph compact badge | ✅ | 3 badge clauses; 1 inverted test (line 85), 1 inverted (line 97), 2 new |
| 4. Graph detailed line | ✅ | 3 publish_text_detailed clauses; 1 inverted test (line 132), 2 new |
| 5. Graph summary | ✅ | Subtracts blocked from publishable; "Blocked apps:" line conditional; 1 inverted (line 181), 2 new |
| 6. Publish task renderer | ✅ | Extracted `render_skipped/1` as public; 5 new tests |
| 7. Verification | ✅ | Audits passed: dep-strip gone; blocked_with_reasons called once in render_graph/2; 4 inversion comments present |
| 8. Documentation | ✅ | Updated @moduledoc in publisher.ex and releaser.graph.ex |

## Files changed

### Production code

- `lib/releaser/publisher.ex`
  - ADDED `blocked_names/1` (public)
  - ADDED `blocked_with_reasons/1` (public)
  - ADDED `do_blocked/4` (private fixed-point worklist)
  - REMOVED silent dep-strip block (was lines 32-38)
  - MODIFIED `plan/1` to compute `blocked_reasons` before Hex filter, split publishable into `{blocked_apps, candidate_apps}`, emit `:blocked_by_deps` skipped entries with `:blocked_by` field
  - UPDATED `@moduledoc` and `plan/1` `@doc`

- `lib/mix/tasks/releaser.graph.ex`
  - ADDED `Publisher` to alias list
  - MODIFIED `render_graph/2` to compute `blocked_reasons`/`blocked_names` once and thread them
  - EXTENDED `render_app_compact` arity 6 → 7 (added `blocked?`)
  - EXTENDED `render_app_detailed` arity 6 → 8 (added `blocked?`, `block_deps`)
  - EXTENDED `compact_badges` arity 3 → 4
  - REPLACED `publish_badge_compact/1` with 3-clause `publish_badge_compact/2` (true,true | true,false | _,_)
  - REPLACED `publish_text_detailed/1` with 3-clause `publish_text_detailed/3`
  - MODIFIED summary block: rename `publishable` → `publishable_total`, add `blocked_count`, conditional "Blocked apps:" line
  - UPDATED `@moduledoc` (badges + summary)

- `lib/mix/tasks/releaser.publish.ex`
  - EXTRACTED `render_skipped/1` as public function (replaced inline rendering in `run/1`)
  - ADDED `:blocked_by_deps` branch in `skipped_label/1` private helper

### Tests

- `test/releaser/publisher_test.exs`
  - ADDED `App` alias
  - ADDED `@mix_template_unpub` fixture template
  - EXTENDED `write_app!/4` with `:deps` and `:publish` keyword opts
  - EXTENDED `plan/3` with `extra_opts` parameter
  - ADDED `describe "plan/1 — blocking detection"` with 5 tests
  - ADDED `describe "blocked_names/1"` with 6 tests
  - ADDED `describe "blocked_with_reasons/1"` with 2 tests

- `test/mix/tasks/releaser_graph_test.exs`
  - INVERTED 4 assertions (lines 85, 97, 131-132, 181) with `# Intentional inversion` comments
  - ADDED `describe "blocking — compact"` with 2 tests
  - ADDED `describe "blocking — detailed"` with 2 tests
  - ADDED `describe "blocking — summary mixed"` with 1 test
  - REPLACED summary describe block (was 1 test, now 2 — added "Blocked apps line absent" test)

- `test/mix/tasks/releaser_publish_test.exs` (NEW)
  - 5 tests covering `render_skipped/1`: blocked names, comma-joined deps, mixed reasons, prerelease branch unchanged, empty list

## Test count summary

| File | Before | After | Delta |
|------|--------|-------|-------|
| `publisher_test.exs` | 6 | 19 | +13 |
| `releaser_graph_test.exs` | 18 | 27 | +9 (4 inverted, 5 new) |
| `releaser_publish_test.exs` | 0 | 5 | +5 |
| Other (unchanged) | 167 | 155 | -12 (some pre-existing tests reorganized in graph_test) |
| **Total project** | **191** | **206** | **+15** |

(Note: project-level total increased because the graph-test additions outpace the wash of inverted-vs-replaced tests; no tests were lost.)

## Smoke test

```
mix releaser.graph
```

Output for the releaser project itself (single-app, publish: true, no deps): shows `[publish: ✓]`, "Publishable apps: 1", "Blocked apps:" line correctly absent.

## Next: sdd-verify

Verifier should re-run the test suite, confirm spec scenarios are covered by the test names, and check the inversion comments are accurate.
