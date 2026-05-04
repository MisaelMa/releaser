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
