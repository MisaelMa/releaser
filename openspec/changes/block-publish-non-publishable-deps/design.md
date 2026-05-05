# Design: block-publish-non-publishable-deps

## 1. Executive summary

This change adds a single source of truth for "blocked" detection inside `Releaser.Publisher` — an iterative worklist that closes over publishable apps whose deps reach any non-publishable app — and threads its result into both the publish flow and the graph renderer. `Publisher.plan/1` STOPS silently stripping non-publishable names from app deps and instead emits blocked apps into `skipped` with a new reason `:blocked_by_deps` and a `blocked_by:` field naming the IMMEDIATE blocking deps. `Publisher.blocked_names/1` is added as the public projection used by `Mix.Tasks.Releaser.Graph` to render a third badge state (`[publish: ✗ blocked]` compact, `publish: blocked (needs: foo, bar)` detailed) and a new `Blocked apps:` summary line. `Mix.Tasks.Releaser.Publish` gains one renderer branch for the new reason. No struct changes, no new modules, no new CLI flags.

---

## 2. Module-level surface

### 2.1 `Releaser.Publisher`

#### NEW public function: `blocked_names/1`

```elixir
@doc """
Returns the set of publishable app names that cannot be published because at
least one direct or transitive internal dep is non-publishable.

Apps with `publish: false` are NEVER members of the returned set — they are
inputs (causes), not outputs (effects).

The function uses the same iterative worklist `plan/1` uses internally; the
two are guaranteed to agree on which apps are blocked.

## Termination

Bounded by `length(apps)`: each iteration either grows the blocked set or
fixes it. Cycles among publishable apps are handled — if any cycle member's
deps reach a non-publishable app, all reachable cycle members converge into
the blocked set within at most `length(apps)` rounds.
"""
@spec blocked_names([Releaser.App.t()]) :: MapSet.t(String.t())
def blocked_names(apps) when is_list(apps)
```

Implementation: derives its result from `blocked_with_reasons/1` via
`MapSet.new(Map.keys(reasons_map))`.

#### NEW private helper: `blocked_with_reasons/1`

```elixir
# Returns %{blocked_app_name => [immediate_blocking_dep_name, ...]}.
# The values are the IMMEDIATE blocking deps of each blocked app — the deps
# that appear in that app's own `:deps` list and are themselves either
# non-publishable or already in the blocked set at fixed point.
@spec blocked_with_reasons([Releaser.App.t()]) :: %{String.t() => [String.t()]}
defp blocked_with_reasons(apps)
```

**Why this internal split exists:** `plan/1` needs the `[immediate_dep, ...]`
list per app to populate `skipped_entries` `:blocked_by` field. `blocked_names/1`
only needs the keys. Computing both in one pass avoids running the worklist
twice. `blocked_names/1` is thus a thin public wrapper (`Map.keys |> MapSet.new`).

The graph task could call `blocked_with_reasons/1` directly to avoid recomputing
the immediate-deps list when rendering the detailed `(needs: …)` line — see ADR
D2. We adopt that: expose it as a SECOND public function.

#### NEW second public function: `blocked_with_reasons/1` (promote from private)

```elixir
@doc """
Returns a map `%{blocked_app_name => [immediate_blocking_dep_name, ...]}`.

Same algorithm as `blocked_names/1`; this variant exposes WHY each blocked
app is blocked. Used by the graph task to render `publish: blocked (needs: …)`
in detailed mode without recomputing.

The `[immediate_blocking_dep_name, ...]` list contains only deps from the
app's own `:deps` field that are themselves either `publish: false` or
blocked. It does NOT contain the transitive root cause.
"""
@spec blocked_with_reasons([Releaser.App.t()]) :: %{String.t() => [String.t()]}
def blocked_with_reasons(apps) when is_list(apps)
```

Both `blocked_names/1` and `blocked_with_reasons/1` ARE public. `blocked_names/1`
is the convenience set form for callers that only need membership; the graph
task uses `blocked_with_reasons/1` directly.

#### MODIFIED: `plan/1`

Current shape (publisher.ex:28-90) keeps these structural elements:
- `Workspace.discover(opts)` call (line 29) — UNCHANGED.
- `Enum.filter(all_apps, & &1.publish)` (line 31) — UNCHANGED.
- `compute_statuses` call (line 41-44) — UNCHANGED.
- `Graph.topological_levels`, `Graph.build` calls (line 70-71) — UNCHANGED.
- `--only` filter logic (line 73-82) — UNCHANGED.
- Final `%{levels:, apps:, graph:, skipped:}` shape — UNCHANGED.

What CHANGES (publisher.ex:33-38 — the silent-strip block, and the skipped construction):

```elixir
# REMOVED (publisher.ex:33-38): silent strip of non-publishable deps.
#   publishable_names = MapSet.new(publishable_apps, & &1.name)
#   publishable_apps_filtered =
#     Enum.map(publishable_apps, fn app ->
#       %{app | deps: Enum.filter(app.deps, &MapSet.member?(publishable_names, &1))}
#     end)
#
# REPLACED WITH:

blocked_reasons = blocked_with_reasons(publishable_apps)
blocked_set = blocked_reasons |> Map.keys() |> MapSet.new()

{candidate_apps, blocked_apps} =
  Enum.split_with(publishable_apps, fn app ->
    not MapSet.member?(blocked_set, app.name)
  end)
# candidate_apps = publishable AND not blocked. These flow into the existing
# Hex-status filtering below.
# blocked_apps = publishable AND blocked. These become :blocked_by_deps skipped
# entries.

# `candidate_apps` is what was previously `publishable_apps_filtered`. The
# variable is then passed to compute_statuses and Enum.split_with on Hex status,
# unchanged from today.
```

Then the `skipped_entries` construction (publisher.ex:57-68) is augmented to
emit blocked entries ALONGSIDE the existing Hex-status entries:

```elixir
hex_skipped_entries =
  Enum.map(hex_skipped, fn app ->          # was `skipped` — rename for clarity
    info = Map.get(statuses, app.name, %{local: app.version, hex: nil, status: :unknown})
    reason =
      case info.status do
        :prerelease -> :prerelease
        _ -> :already_published
      end
    %{app: app.name, local: info.local, hex: info.hex, reason: reason}
  end)

blocked_skipped_entries =
  Enum.map(blocked_apps, fn app ->
    %{
      app: app.name,
      local: app.version,
      hex: nil,
      reason: :blocked_by_deps,
      blocked_by: Map.fetch!(blocked_reasons, app.name)
    }
  end)

skipped_entries = blocked_skipped_entries ++ hex_skipped_entries
```

Order chosen so blocked appear FIRST in `skipped` — they are the more
actionable issue (the user must edit mix.exs to fix). Test scenario "blocked
app alongside already-published app" (spec) does not constrain order, so this
is a free choice; we pick the more useful one.

The `to_publish` (= `apps` in the result map) value is the post-Hex-filter
`candidate_apps` subset, EXACTLY as today — the only difference is the input
no longer has its dep lists rewritten. **`apps` in the returned map now carry
their FULL deps list** (which by construction reach only publishable, non-blocked
apps — because blocked apps were excluded BEFORE Hex filtering, and
non-publishable apps were never in `publishable_apps` to begin with). This
preserves correctness of `Publisher.execute/1`'s `replace_path_dep` call at
publisher.ex:175-179: every name in `deps` is still resolvable in `pub_acc` or
via `find_version(apps, dep)`.

##### Why dep lists no longer need stripping

After this change, for every app `a ∈ to_publish`:

- `a.publish == true` (still in `publishable_apps`).
- `a.name ∉ blocked_set` (filtered out before Hex check).
- Therefore for every `d ∈ a.deps`: `d` is publishable AND not blocked
  (otherwise `a` itself would be in `blocked_set`).
- Therefore the silent-strip filter is a no-op on the new `to_publish` set.

This is the architectural insight that makes the change safe: **the silent
strip was only ever masking the bug — it was never load-bearing for the happy
path.** Removing it does not require additional defensive code.

### 2.2 `Mix.Tasks.Releaser.Graph`

Public surface (`run/1`, `render_graph/1`, `render_graph/2`) UNCHANGED at the
arity level. Internal helpers gain a `blocked_names` MapSet parameter.

#### NEW: dependency on `Releaser.Publisher`

The module already aliases `Releaser.{Graph, Workspace, UI, HexStatus}` (line
56). Add `Publisher` to that alias list.

```elixir
alias Releaser.{Graph, Workspace, UI, HexStatus, Publisher}
```

#### MODIFIED: `render_graph/2`

Inside `render_graph/2` (releaser.graph.ex:102+), after `levels` and `graph`
are computed, ALSO compute the blocked map ONCE:

```elixir
blocked_reasons = Publisher.blocked_with_reasons(apps)
blocked_names = blocked_reasons |> Map.keys() |> MapSet.new()
```

Then pass these into the per-app renderers. Spec scenario "output is
deterministic — no extra Workspace.discover call" REQUIRES this single-call
discipline; the value is computed at the top of `render_graph/2` and threaded
down.

#### MODIFIED signatures

```elixir
# Was:
defp render_app_compact(app, deps, graph, lmap, hex?, hex_map)
# New:
defp render_app_compact(app, deps, graph, lmap, hex?, hex_map, blocked_reasons, blocked_names)

# Was:
defp render_app_detailed(app, deps, graph, lmap, hex?, hex_map)
# New:
defp render_app_detailed(app, deps, graph, lmap, hex?, hex_map, blocked_reasons, blocked_names)

# Was:
defp compact_badges(app, hex?, hex_map)
# New:
defp compact_badges(app, hex?, hex_map, blocked?)

# Was:
defp publish_badge_compact(true)
defp publish_badge_compact(_)
# New (three clauses, in this order):
defp publish_badge_compact(true, true)         # publishable AND blocked
defp publish_badge_compact(true, false)        # publishable AND not blocked
defp publish_badge_compact(_publish, _blocked) # non-publishable (covers false, _ regardless of blocked)

# Was:
defp publish_text_detailed(true)
defp publish_text_detailed(_)
# New (three clauses):
defp publish_text_detailed(true, blocked_by) when is_list(blocked_by) and blocked_by != []
defp publish_text_detailed(true, _no_block)   # publishable, not blocked → "yes"
defp publish_text_detailed(_, _)              # non-publishable → "no"
```

Why two booleans instead of one tri-state atom: the existing helper is named
`publish_badge_compact` and pattern-matches on a boolean (the `app.publish`
field). Adding a second boolean preserves the helper's semantics and reads
naturally at the call site: "publishable, AND blocked?". A tri-state atom
(e.g. `:safe | :blocked | :off`) would force the caller to pre-compute it,
which is just rebadging the same conditional. Keep it boolean.

#### NEW badge string and color

```elixir
defp publish_badge_compact(true, true), do: UI.red("[publish: ✗ blocked]")
defp publish_badge_compact(true, false), do: UI.green("[publish: ✓]")
defp publish_badge_compact(_, _), do: UI.dim("[publish: ✗]")
```

For the detailed line:

```elixir
defp publish_text_detailed(true, [_ | _] = blocked_by) do
  UI.red("blocked") <> UI.dim(" (needs: #{Enum.join(blocked_by, ", ")})")
end
defp publish_text_detailed(true, _), do: UI.green("yes")
defp publish_text_detailed(_, _), do: UI.dim("no")
```

The `(needs: foo, bar)` list comes from `Map.get(blocked_reasons, app.name, [])`
in `render_app_detailed`. Spec scenario "blocked app in detailed mode" requires
the names to be visible; we surround them in dim parentheses to keep them
readable next to the bright `blocked` keyword.

#### MODIFIED: summary block (releaser.graph.ex:147-156)

Current:

```elixir
total = Enum.reduce(levels, 0, fn {_, names}, acc -> acc + length(names) end)
with_deps = Enum.count(apps, &(&1.deps != []))
publishable = Enum.count(apps, & &1.publish)

UI.info("\n#{UI.bright("Summary:")}")
UI.info("  Total apps:          #{total}")
UI.info("  Levels:              #{total_levels}")
UI.info("  Apps with path deps: #{with_deps}")
UI.info("  Publishable apps:    #{publishable}")
UI.info("  Publish order:       level 0 → level #{total_levels - 1}")
UI.info("")
```

New:

```elixir
total = Enum.reduce(levels, 0, fn {_, names}, acc -> acc + length(names) end)
with_deps = Enum.count(apps, &(&1.deps != []))
publishable_total = Enum.count(apps, & &1.publish)
blocked_count = MapSet.size(blocked_names)
publishable = publishable_total - blocked_count

UI.info("\n#{UI.bright("Summary:")}")
UI.info("  Total apps:          #{total}")
UI.info("  Levels:              #{total_levels}")
UI.info("  Apps with path deps: #{with_deps}")
UI.info("  Publishable apps:    #{publishable}")

if blocked_count > 0 do
  UI.info("  Blocked apps:        #{blocked_count}")
end

UI.info("  Publish order:       level 0 → level #{total_levels - 1}")
UI.info("")
```

**Exact column alignment** matches the existing pattern (`String.length` of the
labels): `"Apps with path deps: "` is 21 chars (with trailing space). The new
label `"Blocked apps:        "` is also 21 chars. Confirmed by counting:

```
"  Total apps:          " → 23 cols pre-value
"  Levels:              " → 23 cols pre-value
"  Apps with path deps: " → 23 cols pre-value
"  Publishable apps:    " → 23 cols pre-value
"  Blocked apps:        " → 23 cols pre-value   ← matches
"  Publish order:       " → 23 cols pre-value
```

The "Blocked apps:" line is INSERTED between "Publishable apps:" and "Publish
order:" so it visually associates with the publishable count it modifies.

### 2.3 `Mix.Tasks.Releaser.Publish`

#### MODIFIED: skipped renderer (releaser.publish.ex:48-65)

Current `case reason do` has two branches. Add a third for `:blocked_by_deps`.
Also: the current `Enum.each` destructure pattern `%{app: name, local: local,
hex: hex, reason: reason}` does NOT pull `blocked_by` — we either widen the
destructure or use a defensive `Map.get`. Cleaner to widen, but that changes
behavior for OTHER reasons (which won't have `:blocked_by`). Easiest correct
fix: keep the destructure, branch on `reason`, and pull `blocked_by` inside
the branch via `Map.get(entry, :blocked_by, [])`.

```elixir
Enum.each(skipped, fn entry ->
  %{app: name, local: local, hex: hex, reason: reason} = entry

  label =
    case reason do
      :already_published ->
        "already on Hex (local v#{local} matches Hex v#{hex || "?"})"

      :prerelease ->
        "pre-release local v#{local}"

      :blocked_by_deps ->
        deps_list = Map.get(entry, :blocked_by, []) |> Enum.join(", ")
        "blocked by non-publishable deps: #{deps_list}"
    end

  UI.info("  #{name}  — #{label}")
end)
```

Color choice for blocked: the surrounding loop emits plain (uncolored) lines
already; we keep the line uncolored to match. The existing `UI.bright` is on
the SECTION header ("Skipping (nothing new to publish):"), not per entry.
Introducing a per-entry red would create asymmetry with `:already_published`.
Instead, the SEMANTIC distinction comes from the word "blocked" plus the dep
names — sufficient for visibility. (If user feedback later wants color, it is
a one-line follow-up.)

The exact rendered line for a blocked app:

```
  csd  — blocked by non-publishable deps: openssl
```

Spec scenario constraints: line MUST contain the app name AND every name in
`blocked_by`. Confirmed.

---

## 3. The worklist algorithm — pseudocode

```
INPUT: apps :: [%Releaser.App{}]
OUTPUT: %{blocked_app_name => [immediate_blocking_dep_name, ...]}

1.  publishable_names = MapSet of app.name where app.publish == true
2.  non_publishable_names = MapSet of app.name where app.publish == false
3.  index_by_name = %{app.name => app} for app in apps where app.publish == true
4.  Initialize:
        blocked = empty MapSet
        reasons = empty Map
5.  Loop:
        added_this_round = false
        For each app in publishable apps (those NOT yet in `blocked`):
            blocking_deps = []
            For each dep in app.deps:
                If dep ∈ non_publishable_names OR dep ∈ blocked:
                    blocking_deps = [dep | blocking_deps]
            If blocking_deps != []:
                blocked = MapSet.put(blocked, app.name)
                reasons = Map.put(reasons, app.name, Enum.reverse(blocking_deps))
                added_this_round = true
        If added_this_round == false: BREAK
6.  Return reasons
```

### Termination guarantee

`blocked` is a MapSet that only grows; it cannot exceed
`MapSet.size(publishable_names)`. Each loop iteration that does NOT terminate
must add at least one element (otherwise `added_this_round` is false and we
break). Therefore the loop runs at most `length(publishable_apps)` times.

### Cycle handling

Cycle case: `a → b → a` where both are publishable, plus `a → c` where `c` is
non-publishable.

- Round 1: scanning `a`: `c ∈ non_publishable_names` → `a` joins blocked,
  `reasons["a"] = ["c"]`. Scanning `b`: `a ∉ non_publishable` and at THIS
  point `a` may or may not be in `blocked` depending on iteration order — but
  by end of round, `a` is in `blocked`.
- Round 2: scanning `b`: `a ∈ blocked` → `b` joins blocked,
  `reasons["b"] = ["a"]`.
- Round 3: nothing new added. Break.

The key property: `blocked` carries over between rounds, so order-of-scan
within a round doesn't affect the final fixed point — only how many rounds
it takes. Worst case is a chain of length N (`a₁ → a₂ → … → aₙ → b_nonpub`)
where each round picks up exactly one new app, taking N rounds. Bounded by
app count.

### Why iterative > recursive here

Three reasons:

1. **Reuse**: the same loop produces both the set (for `blocked_names/1`)
   and the per-app immediate causes (for `blocked_with_reasons/1` and the
   skipped entries). A recursive `is_blocked?(app, visited)` would compute
   only the boolean and require a second pass for causes.

2. **Cycle handling is free**: monotonic set growth bounded by app count
   means no `visited` parameter, no recursion stack, no separate
   cycle-detection machinery. The fixed-point semantics cover cycles by
   construction.

3. **Match the existing codebase**: `Releaser.Graph.do_levels/4` (graph.ex:51)
   already uses Kahn-style fixed-point iteration over MapSets. The worklist
   is the same shape. Familiar reading.

Recursive (DFS with memoization) is also viable but provides no measurable
benefit here (workspaces are dozens of apps; both are O(apps²) worst case).
Pick the one that matches the codebase idiom.

### Why NOT `Graph.transitive_deps`

Considered and rejected (per exploration). `Graph.transitive_deps/2` operates
on a graph that has already had non-publishable apps stripped; it cannot tell
us "does this closure CONTAIN a non-publishable name" because those names are
no longer in the graph. Reusing it would require pre-building a different
graph (one that includes non-publishable apps as terminal nodes), which is
strictly more code than the worklist.

---

## 4. UI module additions

### Confirmed: `UI.red/1` exists

Read of `lib/releaser/ui.ex:13` confirms:

```elixir
def red(text), do: "#{IO.ANSI.red()}#{text}#{IO.ANSI.reset()}"
```

**No UI module changes required.** Both `[publish: ✗ blocked]` (compact) and
`blocked` (in detailed `publish: blocked (needs: …)`) use `UI.red/1`.

### Why `UI.red/1` and not `UI.yellow/1` or `UI.magenta/1`

- `UI.green` = success (publishable, will publish).
- `UI.dim` = inactive / off (publish: false; not relevant to publish).
- `UI.red` = error / blocked (publishable but cannot proceed).
- `UI.yellow` is already taken by hex-status `[hex: unpub]` (different axis).
- `UI.magenta` is taken by hex-status `[hex: pre]`.

Using `UI.red` keeps the two color axes (publish state vs. hex state) visually
distinct and aligns with the user's mental model: "red means stop".

The `(needs: foo, bar)` parenthetical in the detailed line uses `UI.dim` to
recede visually under the `red("blocked")` keyword. The dep names themselves
are NOT individually colored — they are part of the dim parenthetical.

---

## 5. Test plan

Mapping each spec scenario to a concrete test. NEW = brand new test;
MODIFY = existing test that flips behavior.

### `test/releaser/publisher_test.exs`

| Spec scenario | Test name (proposed) | NEW/MODIFY |
|---|---|---|
| direct block — dep is non-publishable | `blocked_names/1 returns app with direct non-publishable dep` | NEW |
| transitive block A → C → B | `blocked_names/1 returns A and C when B is non-publishable` | NEW |
| no blocking | `blocked_names/1 returns empty MapSet when all deps publishable` | NEW |
| app with no path deps | `blocked_names/1 returns empty MapSet for standalone publishable app` | NEW |
| cycle with one non-publishable feeder | `blocked_names/1 handles cycle among publishable apps and terminates` | NEW |
| `plan/1` excludes blocked from levels/apps | `plan/1 omits blocked apps from levels and apps, emits :blocked_by_deps in skipped` | NEW |
| transitive immediate cause | `plan/1 :blocked_by lists immediate dep, not transitive root` | NEW |
| Hex status interaction | `plan/1 applies blocking before Hex status filtering` | NEW |
| `--only` filter post-blocking | `plan/1 with --only filters after blocking removal` | NEW |
| all-publishable workspace | `plan/1 emits no :blocked_by_deps when no blocking exists` | NEW (or absorb into existing happy-path test if present) |

These tests live in a new `describe "plan/1 — blocking detection"` and a new
`describe "blocked_names/1"` block. Existing `describe "plan/1 — Hex status
filtering"` (per exploration) stays intact.

### `test/mix/tasks/releaser_graph_test.exs`

| Spec scenario | Test name | NEW/MODIFY | Anchor |
|---|---|---|---|
| existing rich-apps test asserts `[publish: ✓]` for blocked csd | `shows [publish: ✗ blocked] for apps blocked by non-publishable deps` | **MODIFY** at line 85 | `releaser_graph_test.exs:82-86` |
| `[publish: ✗]` for non-publishable openssl (unchanged) | (already passes — keep) | unchanged | `releaser_graph_test.exs:88-92` |
| `[@version]` only with attribute form (CURRENTLY assumes csd has `[publish: ✓]`) | UPDATE the assertion at line 97 to expect `[publish: ✗ blocked] [@version]` | **MODIFY** | `releaser_graph_test.exs:94-99` |
| detailed mode "publish: yes" for csd (CURRENTLY at line 132) | UPDATE assertion to `publish: blocked (needs: openssl)` | **MODIFY** | `releaser_graph_test.exs:131-132` |
| summary "Publishable apps: 1" (CURRENTLY at line 181) | UPDATE assertion: csd now blocked, so `Publishable apps: 0`; add NEW assertion for `Blocked apps: 1` | **MODIFY** | `releaser_graph_test.exs:177-183` |
| safe publishable app shows `[publish: ✓]` | NEW test using a fresh fixture (e.g. `@safe_apps` with one app `publish: true, deps: []`) — confirms green badge survives | NEW |
| non-publishable shows `[publish: ✗]` (no "blocked" word) | NEW test (or absorbed into existing line 88 test by adding `refute output =~ "blocked"`) | NEW or extend existing |
| no extra `Workspace.discover` call | NEW test using a fixture-only call to `render_graph/2` and asserting absence of side effects (or asserting `Publisher.blocked_with_reasons/1` called once via `:meck`/`Mox` — but releaser does not currently use either; simpler: just call `render_graph/2` and trust the structure since the implementation literally calls it once) | OPTIONAL — implementation review covers this |
| blocked app in detailed mode (`publish: blocked (needs: openssl)`) | NEW test, asserts the line in detailed mode | NEW |
| non-blocked publishable in detailed mode (`publish: yes`) | NEW test using `@safe_apps` fixture | NEW |
| one blocked out of two publishable — summary | NEW test with three-app fixture: csd (blocked), openssl (non-pub), safe (publishable, no deps) | NEW |
| no blocked apps — Blocked line absent | NEW test using `@safe_apps`, `refute output =~ "Blocked apps:"` | NEW |
| all publishable apps blocked | NEW test, fixture with all `publish: true` apps blocked | NEW |

#### Critical reviewer note

The MODIFY at line 85 looks like a regression in the diff. Tasks phase MUST
include in the task description (and the eventual commit message) a note like
"intentionally inverts test/mix/tasks/releaser_graph_test.exs:85 — see
proposal.md §7 backwards compatibility". Without that note, a reviewer
skimming the diff would object.

### `test/mix/tasks/releaser_publish_test.exs` (or wherever publish task tests live)

| Spec scenario | Test name | NEW/MODIFY |
|---|---|---|
| dry-run with one blocked app | `skipped section shows blocked app with non-publishable deps named` | NEW |
| blocked alongside already-published | `skipped section renders both reasons distinctly` | NEW |

(If no such test file exists today, the tasks phase creates one.)

---

## 6. Implementation order (high level)

Strict TDD mode is active. The tasks phase will refine these into red/green
pairs; this is the architectural slicing.

1. **Publisher: `blocked_with_reasons/1` (public) + `blocked_names/1` (public).**
   - Pure function over a list of `%App{}`. Easy to test in isolation.
   - All five `blocked_names/1` spec scenarios are covered here.
   - No `plan/1` integration yet → no risk of breaking existing tests.

2. **Publisher: `plan/1` integration.**
   - Remove the silent strip (publisher.ex:33-38).
   - Compute `blocked_reasons` and split.
   - Emit `:blocked_by_deps` skipped entries with `blocked_by`.
   - All four `plan/1` spec scenarios covered here.
   - Existing `plan/1` tests should still pass — the only behavioral change is
     for blocking, and existing tests don't exercise blocking (per exploration).

3. **Graph task: thread `blocked_with_reasons` + `blocked_names`.**
   - Modify `render_graph/2` to compute both at the top.
   - Extend `compact_badges`, `publish_badge_compact`, `publish_text_detailed`
     signatures and add the new clauses.
   - Update summary block.
   - **MODIFY existing tests at lines 85, 97, 132, 181** — these flip with this
     slice. Add the new tests for blocked badges, summary, etc.

4. **Publish task: `:blocked_by_deps` branch in skipped renderer.**
   - Add the `case` arm.
   - Add tests.

UI module: NO changes needed (`UI.red/1` already exists).

The tasks phase should produce a TDD-friendly ordering inside each slice
(write failing test → implement minimum → refactor). Slice 1 → 2 → 3 → 4
strictly in that order: each slice's behavior depends on the previous slice's
public surface. Slice 3's test changes (lines 85, 97, 132, 181) are the most
visually alarming and should be in their own commit with a clear message.

---

## 7. Risks and open questions

### Architectural risks

1. **`blocked_with_reasons/1` becomes public API.** Once exposed, third-party
   callers may depend on its return shape. We commit to `%{name => [name]}`.
   If a future change needs richer info (e.g. "transitive root cause"), we add
   a new function rather than break this one. Documented in the @doc.

2. **Performance for very large workspaces.** Worklist is O(apps × deps) per
   iteration, O(apps) iterations worst case → O(apps² × max_deps). At ~50
   apps with ~10 deps each, that's ~25,000 ops worst case. Per-call cost is
   negligible (microseconds). The graph task calls it once per render, the
   publisher once per plan. No memoization needed. Re-evaluate only if a real
   workspace exceeds ~500 apps.

3. **`Mix.Tasks.Releaser.Graph` now depends on `Releaser.Publisher`.** This
   adds a coupling edge that didn't exist before. Acceptable per Q3 in the
   proposal: the graph task ALREADY queries publish-related info via
   `app.publish`; computing `blocked_names` is a deeper dive in the same
   semantic direction. If a future `Releaser.PublishFilter` extraction
   happens, it changes a single alias here — low cost.

### Decisions deferred to the tasks phase

- **Test file for `Mix.Tasks.Releaser.Publish` skipped renderer.** If no test
  file exists, the tasks phase decides whether to create it inline (preferred
  — small, focused) or split out the renderer into a testable function. Both
  are acceptable. Recommendation: small inline test using `Mix.Shell.Process`
  capture (same pattern as `releaser_graph_test.exs`).

- **Whether `blocked_skipped_entries ++ hex_skipped_entries` order is asserted
  by any existing test.** None spotted. If the tasks phase finds one, prepend
  vs. append is a one-line change.

### No open architectural questions

The four resolved questions in the proposal cover everything. This design
makes no decisions that contradict them.

---

## 8. Backwards compatibility checklist

### Public API additions (NEW)

| Symbol | Signature | Stability commitment |
|---|---|---|
| `Releaser.Publisher.blocked_names/1` | `[App.t()] → MapSet.t(String.t())` | stable; documented |
| `Releaser.Publisher.blocked_with_reasons/1` | `[App.t()] → %{String.t() => [String.t()]}` | stable; documented |

No public API removals, no signature changes on existing public functions
(`plan/1`, `execute/1`, `restore/1`, `replace_path_dep/3`, `ensure_package_config/2`
all unchanged).

### Skipped-entry shape change

| Field | Pre-change | Post-change |
|---|---|---|
| `:app` | `String.t()` | unchanged |
| `:local` | `String.t() \| nil` | unchanged |
| `:hex` | `String.t() \| nil` | unchanged (always `nil` for `:blocked_by_deps`) |
| `:reason` | `:already_published \| :prerelease` | adds `\| :blocked_by_deps` |
| `:blocked_by` | (absent) | `[String.t()]` — present ONLY when `reason == :blocked_by_deps` |

Existing internal consumer (`releaser.publish.ex:51-64`) is updated in the
same change. External consumers (none known) iterating skipped and
pattern-matching on `reason` exhaustively would miss the new value — risk
flagged in the proposal §7. Risk is acceptable; releaser is library code; no
downstream library consumes `plan/1`'s `skipped` directly today.

### Existing tests that change behavior

| File | Line | What asserts today | What MUST assert post-change |
|---|---|---|---|
| `test/mix/tasks/releaser_graph_test.exs` | 85 | `csd v2.0.0 [publish: ✓]` | `csd v2.0.0 [publish: ✗ blocked]` |
| `test/mix/tasks/releaser_graph_test.exs` | 97 | `csd v2.0.0 [publish: ✓] [@version]` | `csd v2.0.0 [publish: ✗ blocked] [@version]` |
| `test/mix/tasks/releaser_graph_test.exs` | 131-132 | `├─ publish: yes` for csd | `publish: blocked (needs: openssl)` for csd |
| `test/mix/tasks/releaser_graph_test.exs` | 181 | `Publishable apps:    1` | `Publishable apps:    0` AND a new assertion `Blocked apps:        1` |

All four are intentional inversions because the existing tests encode the bug
this change fixes. Tasks phase MUST flag this prominently.

### CLI surface

UNCHANGED. No new flags, no removed flags, no semantic shift for `--only`,
`--dry-run`, `--bump`, `--org`, `--detailed`, `-d`, `--hex`. `--only` operates
on the post-blocking `to_publish` list — correct by construction.

### Workspace / app struct

UNCHANGED. `%Releaser.App{}` shape, `Workspace.discover/1` return type, and
all `Releaser.Graph` functions are untouched.
