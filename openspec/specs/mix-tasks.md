# Spec: Mix.Tasks.Releaser.Graph

## Overview

Mix task for rendering the workspace dependency graph. Supports two modes: levels view (topological layers) and dependents-tree view (single app reverse graph).

---

## Requirements: annotated rendering of project-internal deps in the levels view

In the `run([])` (no-argument, levels view) form, each project-internal dep listed under an app MUST be rendered as `<name>[level][count][deep]` when at least one of the three annotation values (level, dep_count, deep_count) is non-zero. When all three values are zero (a true leaf), the dep MUST be rendered as the bare name with no brackets.

### Scenario 5.1: non-leaf dep is rendered with all three brackets

- GIVEN a workspace where dep `"csd"` has level `1`, `dep_count` of `1`, and `deep_count` of `0`
- WHEN `mix releaser.graph` (no-arg form) is run and ANSI is stripped
- THEN the output contains the text `csd[1][1][0]`

### Scenario 5.2: true leaf dep is rendered as bare name

- GIVEN a workspace where dep `"openssl"` has level `0`, `dep_count` of `0`, and `deep_count` of `0`
- WHEN `mix releaser.graph` (no-arg form) is run and ANSI is stripped
- THEN the output contains the text `openssl`
- AND the output does NOT contain `openssl[`

### Scenario 5.3: dependents-tree form is not affected

- GIVEN any workspace
- WHEN `mix releaser.graph <app>` (single-argument, dependents-tree form) is run
- THEN the output contains no `[level]`, `[count]`, or `[deep]` bracket annotations
- AND the output format is identical to pre-change behavior (indented `└─ <name>` lines)

---

## Requirements: level-based color for the [level] bracket

The `[level]` bracket in the annotated dep string MUST be colored using a deterministic palette that cycles via `rem(level, 6)`:

| rem(level, 6) | Color   | UI helper      |
|---------------|---------|----------------|
| 0             | cyan    | `UI.cyan/1`    |
| 1             | green   | `UI.green/1`   |
| 2             | yellow  | `UI.yellow/1`  |
| 3             | magenta | `UI.magenta/1` |
| 4             | red     | `UI.red/1`     |
| 5             | blue    | `UI.blue/1`    |

The `[count]` and `[deep]` brackets MUST be rendered with `UI.dim/1`. The dep name itself MUST be rendered with `UI.yellow/1` (preserving existing behavior).

### Scenario 6.1: level 0 bracket is cyan

- GIVEN a dep at level `0`
- WHEN `annotate_dep/3` (or equivalent) constructs the annotation string
- THEN the `[0]` segment is wrapped with `UI.cyan/1` ANSI codes

### Scenario 6.2: level 2 bracket is yellow

- GIVEN a dep at level `2` with `dep_count` of `3` and `deep_count` of `1`
- WHEN the annotation string is constructed
- THEN ANSI-stripped output reads `<name>[2][3][1]`
- AND the `[2]` segment is wrapped with `UI.yellow/1` ANSI codes

### Scenario 6.3: level 6 cycles back to cyan

- GIVEN a dep at level `6` (i.e. `rem(6, 6) == 0`)
- WHEN the annotation string is constructed
- THEN the `[6]` segment is wrapped with `UI.cyan/1` ANSI codes (same as level 0)

### Scenario 6.4: [count] and [deep] are rendered dim

- GIVEN any non-leaf dep
- WHEN the annotation string is constructed
- THEN the `[count]` and `[deep]` bracket segments are wrapped with `UI.dim/1` ANSI codes

---

## Requirements: compact-mode blocked badge

The compact publish badge MUST distinguish three states:
- `publish: false` → `[publish: ✗]` dim (unchanged)
- `publish: true` AND name NOT in `Publisher.blocked_names(apps)` → `[publish: ✓]` green (unchanged)
- `publish: true` AND name IN `Publisher.blocked_names(apps)` → `[publish: ✗ blocked]` red (NEW)

`Publisher.blocked_names/1` MUST be called once per `render_graph/2` invocation and
the resulting `MapSet` threaded to the badge function. It MUST NOT call
`Workspace.discover/0` again inside badge rendering.

Previously, only two badge states existed; blocked publishable apps showed `[publish: ✓]`.

### Scenario 7.1: blocked publishable app shows blocked badge

- GIVEN apps `[csd (publish: true, deps: ["openssl"]), openssl (publish: false)]`
- WHEN `render_graph(apps, [])` is called
- THEN the output line for `csd` contains `[publish: ✗ blocked]`
- AND `[publish: ✗ blocked]` is rendered in red (via `UI.red/1`)

### Scenario 7.2: non-publishable app shows unblocked ✗ badge

- GIVEN apps containing `openssl (publish: false)`
- WHEN `render_graph(apps, [])` is called
- THEN the output line for `openssl` contains `[publish: ✗]` (dim, no "blocked" word)

### Scenario 7.3: safe publishable app shows ✓ badge

- GIVEN apps `[standalone (publish: true, deps: [])]`
- WHEN `render_graph(apps, [])` is called
- THEN the output line for `standalone` contains `[publish: ✓]` (green)
- AND does NOT contain `blocked`

### Scenario 7.4: output is deterministic — no extra Workspace.discover call

- GIVEN `render_graph/2` is called with a pre-built apps list
- WHEN the function executes
- THEN `Workspace.discover/0` is NOT called inside `render_graph/2` or any badge helper
- AND `Publisher.blocked_names/1` is called exactly once with the provided apps list

---

## Requirements: detailed-mode blocked line

In detailed mode, when an app is blocked, the `publish:` line MUST render
`publish: blocked (needs: <comma-joined immediate non-publishable dep names>)` in red.
When an app is non-blocked and `publish: true`, the line renders `publish: yes` green
(unchanged). When `publish: false`, renders `publish: no` dim (unchanged).

Previously, only `yes` and `no` states existed; blocked apps showed `yes`.

### Scenario 8.1: blocked app in detailed mode

- GIVEN apps `[csd (publish: true, deps: ["openssl"]), openssl (publish: false)]`
- WHEN `render_graph(apps, [detailed: true])` is called
- THEN the detailed block for `csd` contains the line `publish: blocked (needs: openssl)`
- AND `openssl` name in the line is rendered in red or otherwise highlighted

### Scenario 8.2: non-blocked publishable app in detailed mode

- GIVEN apps `[safe_app (publish: true, deps: [])]`
- WHEN `render_graph(apps, [detailed: true])` is called
- THEN the detailed block for `safe_app` contains `publish: yes` (green)
- AND does NOT contain the word `blocked`

---

## Requirements: summary section reflects blocked

The summary section MUST subtract blocked apps from the "Publishable apps" count.
When the count of blocked apps M > 0, a new line "Blocked apps: M" MUST appear in
the summary. When M = 0, the "Blocked apps:" line MUST be absent.

Previously, "Publishable apps: N" counted all apps with `publish: true`, including blocked ones;
no "Blocked" line existed.

### Scenario 9.1: one blocked app out of two publishable

- GIVEN apps `[csd (publish: true, deps: ["openssl"]), openssl (publish: false), safe (publish: true, deps: [])]`
  (csd is blocked, safe is not)
- WHEN `render_graph(apps, [])` is called
- THEN the summary contains `Publishable apps:    1` (safe only)
- AND the summary contains `Blocked apps:        1`

### Scenario 9.2: no blocked apps — Blocked line absent

- GIVEN a workspace with no blocked apps
- WHEN `render_graph(apps, [])` is called
- THEN the summary does NOT contain a "Blocked apps:" line

### Scenario 9.3: all publishable apps blocked

- GIVEN all `publish: true` apps are blocked
- WHEN `render_graph(apps, [])` is called
- THEN `Publishable apps:    0`
- AND `Blocked apps:        N` where N equals the number of `publish: true` apps
