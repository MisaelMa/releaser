# Spec: Mix.Tasks.Releaser.Publish

## Overview

Mix task for publishing apps to Hex according to a computed plan. Renders plan output with
dry-run and execute modes, and reports on skipped apps with reasons.

---

## Requirements: skipped reason :blocked_by_deps rendering

The skipped-entry renderer in `mix releaser.publish` MUST handle
`reason: :blocked_by_deps`. It MUST output a line that names the blocked app and
lists the immediate blocking dep names from `blocked_by`. The line MUST be visually
distinct from `:already_published` and `:prerelease` lines. Suggested form:
`~ <app_name> skipped — blocked by non-publishable deps: <comma-joined blocked_by names>`.
The exact wording MAY vary; the app name and ALL `blocked_by` names MUST appear in
the output. The existing `:already_published` and `:prerelease` rendering MUST remain
unchanged.

### Scenario 1.1: dry-run with one blocked app

- GIVEN apps `[csd (publish: true, deps: ["openssl"]), openssl (publish: false)]`
  and Hex statuses indicating `csd` would be `:ahead`
- WHEN `mix releaser.publish --dry-run` is executed (or `Publisher.plan/1` result rendered)
- THEN the skipped section output contains a line for `csd`
- AND that line includes the text `blocked` and the name `openssl`
- AND `csd` does NOT appear in the levels/publish section

### Scenario 1.2: blocked app alongside already-published app

- GIVEN `skipped` contains `%{app: "a", reason: :blocked_by_deps, blocked_by: ["b"]}` and
  `%{app: "c", reason: :already_published, local: "1.0.0", hex: "1.0.0"}`
- WHEN the skipped section is rendered
- THEN `"a"` line mentions `blocked` and `"b"`
- AND `"c"` line mentions `already on Hex` (or equivalent existing wording)
- AND neither line's output is confused with the other reason's format
