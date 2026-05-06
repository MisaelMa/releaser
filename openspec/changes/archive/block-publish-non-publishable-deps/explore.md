# Exploration: block-publish-non-publishable-deps

## Current State

**`lib/releaser/publisher.ex` — `Publisher.plan/1`**

- Lines 31-32: `Enum.filter(all_apps, & &1.publish)` correctly gates publishable apps.
- Lines 33-38: The dep-trimming filter at line 37 removes non-publishable deps SILENTLY. When app A (`publish: true`) depends on B (`publish: false`), B is stripped from A's deps. A's topological sort succeeds and A gets published with the dep effectively missing — producing a broken Hex package.
- Lines 46-68: `skipped_entries` has exactly two reason values: `:already_published` and `:prerelease`. No third reason exists.

**`lib/mix/tasks/releaser.publish.ex` — sole `skipped` consumer**

Lines 51-64 are the ONLY place in the codebase that reads and renders `skipped`. The `case reason do` has exactly two branches. A new `:blocked_by_deps` reason needs a third branch here and nowhere else.

**`lib/mix/tasks/releaser.graph.ex`**

- `publish_badge_compact/1` (lines 188-189): dispatches on a bare boolean. No dep awareness.
- `publish_text_detailed/1` (lines 226-227): same.
- Both are called from `compact_badges/2` and `render_app_detailed/6`.

**`lib/releaser/workspace.ex` / `%Releaser.App{}`**

- `publish: false` is the struct default (line 12). Always boolean, never nil.
- Set by `Regex.match?(~r/publish:\s*true/, content)` (line 114).

## Problem

Today an app marked `publish: true` whose internal dep is `publish: false` gets published to Hex with that dep silently stripped — likely broken at runtime. The graph task says `[publish: ✓]` for such an app, lying about the actual outcome.

## Critical Finding: Existing Test Asserts Wrong Behavior

`test/mix/tasks/releaser_graph_test.exs` `@rich_apps` fixture (lines 18-35):
- `openssl`: `publish: false`, no deps
- `csd`: `publish: true`, deps: `["openssl"]` ← this IS the blocking scenario

Line 85 currently asserts:
```
assert output =~ "csd v2.0.0 [publish: ✓]"
```

This will break after the change. It validates today's incorrect rendering. Must be flipped to `[publish: ✗ blocked]`. Proposal/tasks phases must call this out so reviewers don't read it as regression.

## Approaches Considered

### Blocking detection in `Publisher.plan/1`

| Approach | Pros | Cons |
|----------|------|------|
| 1 — Direct check only | ~5 LoC | Misses transitive case A→C→B |
| **2 — Iterative worklist** | Correct for all transitive cases; self-contained; ~15 LoC | A bounded loop |
| 3 — Reuse `Graph.transitive_deps/2` | Reuses existing code | Non-publishable apps not in publishable graph; needs pre-filter; more coupling |

**Recommendation: Approach 2** — iterative worklist.

Algorithm:
1. Collect non-publishable names.
2. Seed blocked: publishable apps whose direct deps intersect non-publishable names.
3. Expand: publishable apps not yet blocked whose deps intersect the blocked set.
4. Repeat until no change.

### Surfacing blocked status in graph task

| Option | Description | Notes |
|--------|-------------|-------|
| a | Duplicate worklist inline in graph task | Drift risk |
| b | Extract to new `Releaser.PublishFilter` module | Clean but adds module |
| **c** | Expose `Publisher.blocked_names/1` | Publisher owns semantics; single call site; minimal surface |

**Recommendation: Option c.** `Publisher.blocked_names(apps) :: MapSet.t(String.t())`. Graph task calls it once after `discover/0`, passes the MapSet into `compact_badges` and `render_app_detailed`.

### Badge format

| Option | Compact | Detailed |
|--------|---------|----------|
| A — Simple | `[publish: ⚠]` | `publish: blocked` |
| **B — With names** | `[publish: ✗ blocked]` | `publish: blocked (needs: foo, bar)` |
| C — Color-only | `[publish: ✓]` in red | same |

**Recommendation: Option B.** Compact uses `✗ blocked` (parallel to `✗`, distinguished by the word). Detailed names the blocking deps so the user knows which ones need `releaser: [publish: true]`.

## Existing Tests Inventory

**`test/releaser/publisher_test.exs`** — `describe "plan/1 — Hex status filtering"`, 6 tests for already-published / ahead / unpublished / pre-release. **Zero tests for blocking** — all blocking tests are new.

**`test/mix/tasks/releaser_graph_test.exs`** — 4 describe blocks (compact, detailed, summary, run/1), 15 tests total.
- Line 85: `csd v2.0.0 [publish: ✓]` — must invert.
- Line 88: `openssl v1.0.0 [publish: ✗]` — stays correct (explicit non-publishable, not blocked).
- Line 180: `Publishable apps: 1` — if summary excludes blocked, this also changes.

## Edge Cases

1. **Transitive blocking (A→C→B, B is `publish: false`)**: worklist handles it — C blocked first, A in expansion.
2. **`--hex` flag with blocked app**: hex badge orthogonal. `[hex: unpub] [publish: ✗ blocked]` is accurate.
3. **Circular deps between publishable apps**: worklist terminates regardless (set is monotonically growing, bounded).
4. **App `publish: true`, no path deps**: never in blocked set.
5. **All apps blocked**: `plan/1` returns `levels: [], apps: [], skipped: [all :blocked_by_deps]`. `execute/1` is a no-op.
6. **`--only` flag**: filters `to_publish` AFTER blocking removal. No extra handling.
7. **Dependents tree (`mix releaser.graph <app>`)**: no badges today. Defer.

## Open Questions for Proposal

1. `blocked_by:` field in skipped entries — shape change to `%{app:, local:, hex:, reason:}` map. Only `releaser.publish.ex` consumes it. Acceptable?
2. Summary counter "Publishable apps" — subtract blocked from count? If yes, `releaser.graph.ex:149` and the test at `releaser_graph_test.exs:180` change.
3. Cross-module call from graph task to Publisher (`Publisher.blocked_names/1`) — acceptable, or prefer extracted helper module?
4. Dependents tree — defer blocked status display? Recommended yes.

## Files in Scope

| File | Change |
|------|--------|
| `lib/releaser/publisher.ex` | Add iterative worklist; expose `blocked_names/1`; emit `:blocked_by_deps` in skipped |
| `lib/mix/tasks/releaser.publish.ex` | Add `case` branch for `:blocked_by_deps` |
| `lib/mix/tasks/releaser.graph.ex` | Thread `blocked_names` MapSet through compact + detailed renderers |
| `test/releaser/publisher_test.exs` | New describe block: blocking detection (direct, transitive, all-blocked, blocked_by field) |
| `test/mix/tasks/releaser_graph_test.exs` | Invert line 85 assertion; add blocked fixtures; cover compact + detailed blocked badges |
