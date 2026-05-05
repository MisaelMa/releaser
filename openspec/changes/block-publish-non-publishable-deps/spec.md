# Delta Spec: block-publish-non-publishable-deps

## Scope

This delta introduces blocking detection across three modules. `Releaser.Publisher` gains
`blocked_names/1` and changes `plan/1` to surface blocked apps in `skipped` instead of
silently stripping their non-publishable deps. `Mix.Tasks.Releaser.Graph` gains a third
publish-badge state (`✗ blocked`) and a summary counter for blocked apps.
`Mix.Tasks.Releaser.Publish` gains a renderer branch for the new `:blocked_by_deps` reason.
No struct shape changes. No new modules.

---

## Delta for Releaser.Publisher

### Capability: blocked_names/1 (ADDED)

`Publisher.blocked_names/1` MUST be a public function that accepts a list of
`%Releaser.App{}` and returns a `MapSet.t(String.t())` of app names that MUST NOT
be published because at least one direct or transitive internal dep is non-publishable
(`publish: false`). The function MUST use the same iterative worklist used by `plan/1`.
It MUST terminate even when publishable apps form dependency cycles among themselves.
Apps with `publish: false` are NEVER included in the returned set (they are inputs to
the computation, not outputs).

#### Scenario: direct block — dep is non-publishable

- GIVEN apps `[a (publish: true, deps: ["b"]), b (publish: false, deps: [])]`
- WHEN `Publisher.blocked_names(apps)` is called
- THEN the result is `MapSet.new(["a"])`
- AND `"b"` is NOT in the result (non-publishable apps are not "blocked", they are the cause)

#### Scenario: transitive block — A depends on C depends on B (non-publishable)

- GIVEN apps `[a (publish: true, deps: ["c"]), c (publish: true, deps: ["b"]), b (publish: false, deps: [])]`
- WHEN `Publisher.blocked_names(apps)` is called
- THEN the result is `MapSet.new(["a", "c"])`

#### Scenario: no blocking — all path deps are publishable

- GIVEN apps where every dep referenced is `publish: true`
- WHEN `Publisher.blocked_names(apps)` is called
- THEN the result is an empty `MapSet`

#### Scenario: app with publish: true and no path deps

- GIVEN an app `standalone (publish: true, deps: [])`
- WHEN `Publisher.blocked_names([standalone])` is called
- THEN the result is an empty `MapSet`

#### Scenario: cycle among publishable apps with one non-publishable feeder

- GIVEN apps `[a (publish: true, deps: ["b", "c"]), b (publish: true, deps: ["a"]), c (publish: false, deps: [])]`
  (a and b form a cycle; c is non-publishable and feeds a)
- WHEN `Publisher.blocked_names(apps)` is called
- THEN the result contains both `"a"` and `"b"` (cycle members are all blocked)
- AND the call terminates (does not loop infinitely)

---

### Capability: plan/1 — exclusion and skipped reason (MODIFIED)

`plan/1` MUST exclude blocked apps from `to_publish` BEFORE applying Hex status
filtering. Blocked apps MUST appear in the `skipped` list with
`reason: :blocked_by_deps` and a non-empty `blocked_by: [String.t()]` field listing the
IMMEDIATE blocking deps of that specific app (the deps that appear in that app's own
`:deps` list and are themselves either non-publishable or blocked). The `blocked_by` field
MUST contain the names of the immediate cause, NOT the transitive root cause.
Existing reasons (`:already_published`, `:prerelease`) and their skipped-entry shape
MUST remain unchanged. The `levels`, `apps`, `graph`, and `skipped` top-level keys
MUST remain unchanged. The `--only` filter operates on the post-blocking `to_publish`
list and is NOT affected by this change.

(Previously: `plan/1` silently stripped non-publishable names from each publishable
app's `:deps` before topological sort; no blocked category existed.)

#### Scenario: direct block — blocked app absent from levels and apps

- GIVEN apps `[a (publish: true, deps: ["b"]), b (publish: false)]` with statuses `%{a: %{status: :ahead}}`
- WHEN `Publisher.plan(statuses: statuses, apps: apps)` is called
- THEN `result.levels` does NOT contain `"a"`
- AND `result.apps` does NOT contain app `"a"`
- AND `result.skipped` contains `%{app: "a", reason: :blocked_by_deps, blocked_by: ["b"]}`

#### Scenario: transitive block — immediate cause, not root

- GIVEN apps `[a (publish: true, deps: ["c"]), c (publish: true, deps: ["b"]), b (publish: false)]`
  with all statuses `:ahead`
- WHEN `Publisher.plan(statuses: ..., apps: apps)` is called
- THEN skipped entry for `"c"` has `blocked_by: ["b"]`
- AND skipped entry for `"a"` has `blocked_by: ["c"]` (immediate dep, not `"b"`)

#### Scenario: Hex status interaction — blocked check before Hex check

- GIVEN app `a (publish: true, deps: ["b"])`, `b (publish: false)`, Hex status of `a` is `:ahead`
- WHEN `Publisher.plan(...)` is called
- THEN `"a"` appears in `skipped` with `reason: :blocked_by_deps`
- AND `"a"` does NOT appear in `levels` or `apps`
- AND the `:already_published` / `:prerelease` reasons are NOT applied to `"a"`

#### Scenario: --only filter is applied after blocking removal

- GIVEN apps `[a, b, c]` where `c` is blocked, `a` and `b` are safe and `:ahead`
- WHEN `Publisher.plan(only: ["a"], ...)` is called
- THEN `result.levels` contains only `"a"` (or its required deps)
- AND `"c"` appears in `skipped` with `:blocked_by_deps` regardless of `--only`

#### Scenario: all-publishable workspace — no skipped with :blocked_by_deps

- GIVEN a workspace where every app with `publish: true` has deps only among other `publish: true` apps
- WHEN `Publisher.plan(...)` is called
- THEN `result.skipped` contains NO entry with `reason: :blocked_by_deps`

---

## Delta for Mix.Tasks.Releaser.Graph

### Capability: compact-mode blocked badge (MODIFIED)

The compact publish badge MUST distinguish three states:
- `publish: false` → `[publish: ✗]` dim (unchanged)
- `publish: true` AND name NOT in `Publisher.blocked_names(apps)` → `[publish: ✓]` green (unchanged)
- `publish: true` AND name IN `Publisher.blocked_names(apps)` → `[publish: ✗ blocked]` red (NEW)

`Publisher.blocked_names/1` MUST be called once per `render_graph/2` invocation and
the resulting `MapSet` threaded to the badge function. It MUST NOT call
`Workspace.discover/0` again inside badge rendering.

(Previously: only two badge states existed; blocked publishable apps showed `[publish: ✓]`.)

#### Scenario: blocked publishable app shows blocked badge

- GIVEN apps `[csd (publish: true, deps: ["openssl"]), openssl (publish: false)]`
- WHEN `render_graph(apps, [])` is called
- THEN the output line for `csd` contains `[publish: ✗ blocked]`
- AND `[publish: ✗ blocked]` is rendered in red (via `UI.red/1`)

#### Scenario: non-publishable app shows unblocked ✗ badge

- GIVEN apps containing `openssl (publish: false)`
- WHEN `render_graph(apps, [])` is called
- THEN the output line for `openssl` contains `[publish: ✗]` (dim, no "blocked" word)

#### Scenario: safe publishable app shows ✓ badge

- GIVEN apps `[standalone (publish: true, deps: [])]`
- WHEN `render_graph(apps, [])` is called
- THEN the output line for `standalone` contains `[publish: ✓]` (green)
- AND does NOT contain `blocked`

#### Scenario: output is deterministic — no extra Workspace.discover call

- GIVEN `render_graph/2` is called with a pre-built apps list
- WHEN the function executes
- THEN `Workspace.discover/0` is NOT called inside `render_graph/2` or any badge helper
- AND `Publisher.blocked_names/1` is called exactly once with the provided apps list

---

### Capability: detailed-mode blocked line (MODIFIED)

In detailed mode, when an app is blocked, the `publish:` line MUST render
`publish: blocked (needs: <comma-joined immediate non-publishable dep names>)` in red.
When an app is non-blocked and `publish: true`, the line renders `publish: yes` green
(unchanged). When `publish: false`, renders `publish: no` dim (unchanged).

(Previously: only `yes` and `no` states; blocked apps showed `yes`.)

#### Scenario: blocked app in detailed mode

- GIVEN apps `[csd (publish: true, deps: ["openssl"]), openssl (publish: false)]`
- WHEN `render_graph(apps, [detailed: true])` is called
- THEN the detailed block for `csd` contains the line `publish: blocked (needs: openssl)`
- AND `openssl` name in the line is rendered in red or otherwise highlighted

#### Scenario: non-blocked publishable app in detailed mode

- GIVEN apps `[safe_app (publish: true, deps: [])]`
- WHEN `render_graph(apps, [detailed: true])` is called
- THEN the detailed block for `safe_app` contains `publish: yes` (green)
- AND does NOT contain the word `blocked`

---

### Capability: summary section reflects blocked (MODIFIED)

The summary section MUST subtract blocked apps from the "Publishable apps" count.
When the count of blocked apps M > 0, a new line "Blocked apps: M" MUST appear in
the summary. When M = 0, the "Blocked apps:" line MUST be absent.

(Previously: "Publishable apps: N" counted all apps with `publish: true`, including blocked ones;
no "Blocked" line existed.)

#### Scenario: one blocked app out of two publishable

- GIVEN apps `[csd (publish: true, deps: ["openssl"]), openssl (publish: false), safe (publish: true, deps: [])]`
  (csd is blocked, safe is not)
- WHEN `render_graph(apps, [])` is called
- THEN the summary contains `Publishable apps:    1` (safe only)
- AND the summary contains `Blocked apps:        1`

#### Scenario: no blocked apps — Blocked line absent

- GIVEN a workspace with no blocked apps
- WHEN `render_graph(apps, [])` is called
- THEN the summary does NOT contain a "Blocked apps:" line

#### Scenario: all publishable apps blocked

- GIVEN all `publish: true` apps are blocked
- WHEN `render_graph(apps, [])` is called
- THEN `Publishable apps:    0`
- AND `Blocked apps:        N` where N equals the number of `publish: true` apps

---

## Delta for Mix.Tasks.Releaser.Publish

### Capability: skipped reason :blocked_by_deps rendering (ADDED)

The skipped-entry renderer in `mix releaser.publish` MUST handle
`reason: :blocked_by_deps`. It MUST output a line that names the blocked app and
lists the immediate blocking dep names from `blocked_by`. The line MUST be visually
distinct from `:already_published` and `:prerelease` lines. Suggested form:
`~ <app_name> skipped — blocked by non-publishable deps: <comma-joined blocked_by names>`.
The exact wording MAY vary; the app name and ALL `blocked_by` names MUST appear in
the output. The existing `:already_published` and `:prerelease` rendering MUST remain
unchanged.

#### Scenario: dry-run with one blocked app

- GIVEN apps `[csd (publish: true, deps: ["openssl"]), openssl (publish: false)]`
  and Hex statuses indicating `csd` would be `:ahead`
- WHEN `mix releaser.publish --dry-run` is executed (or `Publisher.plan/1` result rendered)
- THEN the skipped section output contains a line for `csd`
- AND that line includes the text `blocked` and the name `openssl`
- AND `csd` does NOT appear in the levels/publish section

#### Scenario: blocked app alongside already-published app

- GIVEN `skipped` contains `%{app: "a", reason: :blocked_by_deps, blocked_by: ["b"]}` and
  `%{app: "c", reason: :already_published, local: "1.0.0", hex: "1.0.0"}`
- WHEN the skipped section is rendered
- THEN `"a"` line mentions `blocked` and `"b"`
- AND `"c"` line mentions `already on Hex` (or equivalent existing wording)
- AND neither line's output is confused with the other reason's format
