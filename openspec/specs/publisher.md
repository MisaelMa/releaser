# Spec: Releaser.Publisher

## Overview

Core module for computing the publish plan from a workspace of apps and their Hex status.

---

## Requirements: blocked_names/1

`Publisher.blocked_names/1` MUST be a public function that accepts a list of
`%Releaser.App{}` and returns a `MapSet.t(String.t())` of app names that MUST NOT
be published because at least one direct or transitive internal dep is non-publishable
(`publish: false`). The function MUST use an iterative worklist algorithm.
It MUST terminate even when publishable apps form dependency cycles among themselves.
Apps with `publish: false` are NEVER included in the returned set (they are inputs to
the computation, not outputs).

### Scenario 1.1: direct block — dep is non-publishable

- GIVEN apps `[a (publish: true, deps: ["b"]), b (publish: false, deps: [])]`
- WHEN `Publisher.blocked_names(apps)` is called
- THEN the result is `MapSet.new(["a"])`
- AND `"b"` is NOT in the result (non-publishable apps are not "blocked", they are the cause)

### Scenario 1.2: transitive block — A depends on C depends on B (non-publishable)

- GIVEN apps `[a (publish: true, deps: ["c"]), c (publish: true, deps: ["b"]), b (publish: false, deps: [])]`
- WHEN `Publisher.blocked_names(apps)` is called
- THEN the result is `MapSet.new(["a", "c"])`

### Scenario 1.3: no blocking — all path deps are publishable

- GIVEN apps where every dep referenced is `publish: true`
- WHEN `Publisher.blocked_names(apps)` is called
- THEN the result is an empty `MapSet`

### Scenario 1.4: app with publish: true and no path deps

- GIVEN an app `standalone (publish: true, deps: [])`
- WHEN `Publisher.blocked_names([standalone])` is called
- THEN the result is an empty `MapSet`

### Scenario 1.5: cycle among publishable apps with one non-publishable feeder

- GIVEN apps `[a (publish: true, deps: ["b", "c"]), b (publish: true, deps: ["a"]), c (publish: false, deps: [])]`
  (a and b form a cycle; c is non-publishable and feeds a)
- WHEN `Publisher.blocked_names(apps)` is called
- THEN the result contains both `"a"` and `"b"` (cycle members are all blocked)
- AND the call terminates (does not loop infinitely)

---

## Requirements: blocked_with_reasons/1

`Publisher.blocked_with_reasons/1` MUST be a public function that accepts a list of
`%Releaser.App{}` and returns a `%{String.t() => [String.t()]}` map where each key is
a blocked app name and each value is a list of the IMMEDIATE blocking deps (deps in that
app's own `:deps` that are themselves non-publishable or blocked). The function MUST
use the same fixed-point iteration as `blocked_names/1`.

### Scenario 2.1: immediate causes, not transitive root

- GIVEN apps `[a (publish: true, deps: ["c"]), c (publish: true, deps: ["b"]), b (publish: false, deps: [])]`
- WHEN `Publisher.blocked_with_reasons(apps)` is called
- THEN the result is `%{"c" => ["b"], "a" => ["c"]}`
- AND `"a"` does NOT list `"b"` as a cause (only immediate dep `"c"`)

### Scenario 2.2: multiple immediate blocking deps

- GIVEN apps `[a (publish: true, deps: ["b", "c"]), b (publish: false), c (publish: false)]`
- WHEN `Publisher.blocked_with_reasons(apps)` is called
- THEN the result includes `a: [...]` with both `"b"` and `"c"` in the list

---

## Requirements: plan/1 — exclusion and skipped reason

`plan/1` MUST exclude blocked apps from `to_publish` BEFORE applying Hex status
filtering. Blocked apps MUST appear in the `skipped` list with
`reason: :blocked_by_deps` and a non-empty `blocked_by: [String.t()]` field listing the
IMMEDIATE blocking deps of that specific app. The `blocked_by` field
MUST contain the names of the immediate cause, NOT the transitive root cause.
Existing reasons (`:already_published`, `:prerelease`) and their skipped-entry shape
MUST remain unchanged. The `levels`, `apps`, `graph`, and `skipped` top-level keys
MUST remain unchanged. The `--only` filter operates on the post-blocking `to_publish`
list and is NOT affected by this change.

Previously, `plan/1` silently stripped non-publishable names from each publishable
app's `:deps` before topological sort; no blocked category existed.

### Scenario 3.1: direct block — blocked app absent from levels and apps

- GIVEN apps `[a (publish: true, deps: ["b"]), b (publish: false)]` with statuses `%{a: %{status: :ahead}}`
- WHEN `Publisher.plan(statuses: statuses, apps: apps)` is called
- THEN `result.levels` does NOT contain `"a"`
- AND `result.apps` does NOT contain app `"a"`
- AND `result.skipped` contains `%{app: "a", reason: :blocked_by_deps, blocked_by: ["b"]}`

### Scenario 3.2: transitive block — immediate cause, not root

- GIVEN apps `[a (publish: true, deps: ["c"]), c (publish: true, deps: ["b"]), b (publish: false)]`
  with all statuses `:ahead`
- WHEN `Publisher.plan(statuses: ..., apps: apps)` is called
- THEN skipped entry for `"c"` has `blocked_by: ["b"]`
- AND skipped entry for `"a"` has `blocked_by: ["c"]` (immediate dep, not `"b"`)

### Scenario 3.3: Hex status interaction — blocked check before Hex check

- GIVEN app `a (publish: true, deps: ["b"])`, `b (publish: false)`, Hex status of `a` is `:ahead`
- WHEN `Publisher.plan(...)` is called
- THEN `"a"` appears in `skipped` with `reason: :blocked_by_deps`
- AND `"a"` does NOT appear in `levels` or `apps`
- AND the `:already_published` / `:prerelease` reasons are NOT applied to `"a"`

### Scenario 3.4: --only filter is applied after blocking removal

- GIVEN apps `[a, b, c]` where `c` is blocked, `a` and `b` are safe and `:ahead`
- WHEN `Publisher.plan(only: ["a"], ...)` is called
- THEN `result.levels` contains only `"a"` (or its required deps)
- AND `"c"` appears in `skipped` with `:blocked_by_deps` regardless of `--only`

### Scenario 3.5: all-publishable workspace — no skipped with :blocked_by_deps

- GIVEN a workspace where every app with `publish: true` has deps only among other `publish: true` apps
- WHEN `Publisher.plan(...)` is called
- THEN `result.skipped` contains NO entry with `reason: :blocked_by_deps`
