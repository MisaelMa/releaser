# Delta Spec: annotate-graph-deps

## Scope

Delta specs for three modules: `Releaser.Graph` (3 new helpers), `Releaser.UI` (2 new color helpers), `Mix.Tasks.Releaser.Graph` (annotated rendering in the levels view). The `<app>` dependents-tree form is explicitly OUT of scope.

---

# Delta for Releaser.Graph

## ADDED Requirements

### Requirement 1: level_map/1 — invert topological levels into a name-keyed map

`Releaser.Graph.level_map/1` MUST accept the `[{level, [name]}]` list returned by `topological_levels/1` and return `%{name => level}` so that any caller can look up a dep's level in O(1).

#### Scenario 1.1: happy path — multi-level input

- GIVEN a levels list `[{0, ["c", "d"]}, {1, ["b"]}, {2, ["a"]}]`
- WHEN `Graph.level_map/1` is called with that list
- THEN the result is `%{"a" => 2, "b" => 1, "c" => 0, "d" => 0}`

#### Scenario 1.2: empty input returns empty map

- GIVEN an empty list `[]`
- WHEN `Graph.level_map/1` is called
- THEN the result is `%{}`

#### Scenario 1.3: single level (all leaves)

- GIVEN a levels list `[{0, ["x", "y"]}]`
- WHEN `Graph.level_map/1` is called
- THEN the result is `%{"x" => 0, "y" => 0}`

---

### Requirement 2: dep_count/2 — direct project-internal dep count for a name

`Releaser.Graph.dep_count/2` MUST accept a `name` (string) and a `graph` map (`%{name => [dep_name]}`) and return the integer count of the list at `graph[name]`. It MUST return `0` for any name not present in the graph.

#### Scenario 2.1: known name with deps

- GIVEN a graph `%{"a" => ["b", "c"], "b" => ["c"], "c" => []}`
- WHEN `Graph.dep_count("a", graph)` is called
- THEN the result is `2`

#### Scenario 2.2: known name with no deps

- GIVEN a graph `%{"a" => ["b"], "b" => []}`
- WHEN `Graph.dep_count("b", graph)` is called
- THEN the result is `0`

#### Scenario 2.3: unknown name returns 0

- GIVEN a graph `%{"a" => ["b"]}`
- WHEN `Graph.dep_count("z", graph)` is called
- THEN the result is `0`

---

### Requirement 3: deep_count/2 — shallow count of non-leaf direct deps

`Releaser.Graph.deep_count/2` MUST accept a `name` (string) and a `graph` map and return a **shallow** integer count of how many of `name`'s direct deps themselves have at least one project-internal dep listed in the graph. It MUST NOT recurse further than one level beyond `name`'s direct deps. It MUST return `0` for leaves and for unknown names.

NOTE: `deep_count` is explicitly a shallow metric, not a recursive depth. For a chain `a → b → c` where `c` has no deps, `deep_count("a", graph)` is `1` (only `b` qualifies — it has `c` as a dep), NOT `2`.

#### Scenario 3.1: shallow semantics — 3-node chain

- GIVEN a graph `%{"a" => ["b"], "b" => ["c"], "c" => []}`
- WHEN `Graph.deep_count("a", graph)` is called
- THEN the result is `1` (b has deps; c does not — c is not counted because it is not a direct dep of a)
- AND `Graph.deep_count("b", graph)` is `0` (c is a direct dep of b, but c has no deps, so b has zero non-leaf direct deps)

#### Scenario 3.2: leaf node returns 0

- GIVEN a graph `%{"a" => ["b"], "b" => []}`
- WHEN `Graph.deep_count("b", graph)` is called
- THEN the result is `0`

#### Scenario 3.3: unknown name returns 0

- GIVEN a graph `%{"a" => ["b"]}`
- WHEN `Graph.deep_count("z", graph)` is called
- THEN the result is `0`

#### Scenario 3.4: multiple qualifying direct deps

- GIVEN a graph `%{"root" => ["x", "y", "z"], "x" => ["a"], "y" => ["b"], "z" => []}`
- WHEN `Graph.deep_count("root", graph)` is called
- THEN the result is `2` (x and y each have deps; z has none)

---

# Delta for Releaser.UI

## ADDED Requirements

### Requirement 4: magenta/1 and blue/1 color helpers

`Releaser.UI` MUST expose `magenta/1` and `blue/1` functions. Each MUST wrap the given text with its corresponding ANSI color escape code, followed immediately by `IO.ANSI.reset()`, and return the resulting string. Both MUST follow the exact same pattern as the existing `green/1`, `cyan/1`, `yellow/1`, and `red/1` helpers.

#### Scenario 4.1: magenta/1 wraps text with ANSI magenta and reset

- GIVEN the string `"hello"`
- WHEN `UI.magenta("hello")` is called
- THEN the result starts with the ANSI magenta escape sequence
- AND the result ends with the ANSI reset escape sequence
- AND the string `"hello"` appears between the two sequences

#### Scenario 4.2: blue/1 wraps text with ANSI blue and reset

- GIVEN the string `"world"`
- WHEN `UI.blue("world")` is called
- THEN the result starts with the ANSI blue escape sequence
- AND the result ends with the ANSI reset escape sequence
- AND the string `"world"` appears between the two sequences

#### Scenario 4.3: stripping ANSI leaves the bare text

- GIVEN a call to `UI.magenta("foo")` or `UI.blue("bar")`
- WHEN the ANSI escape sequences are stripped via `~r/\e\[[0-9;]*m/`
- THEN the result is `"foo"` or `"bar"` respectively

---

# Delta for Mix.Tasks.Releaser.Graph

## ADDED Requirements

### Requirement 5: annotated rendering of project-internal deps in the levels view

In the `run([])` (no-argument, levels view) form, each project-internal dep listed under an app MUST be rendered as `<name>[level][count][deep]` when at least one of the three annotation values (level, dep_count, deep_count) is non-zero. When all three values are zero (a true leaf), the dep MUST be rendered as the bare name with no brackets.

#### Scenario 5.1: non-leaf dep is rendered with all three brackets

- GIVEN a workspace where dep `"csd"` has level `1`, `dep_count` of `1`, and `deep_count` of `0`
- WHEN `mix releaser.graph` (no-arg form) is run and ANSI is stripped
- THEN the output contains the text `csd[1][1][0]`

#### Scenario 5.2: true leaf dep is rendered as bare name

- GIVEN a workspace where dep `"openssl"` has level `0`, `dep_count` of `0`, and `deep_count` of `0`
- WHEN `mix releaser.graph` (no-arg form) is run and ANSI is stripped
- THEN the output contains the text `openssl`
- AND the output does NOT contain `openssl[`

#### Scenario 5.3: dependents-tree form is not affected

- GIVEN any workspace
- WHEN `mix releaser.graph <app>` (single-argument, dependents-tree form) is run
- THEN the output contains no `[level]`, `[count]`, or `[deep]` bracket annotations
- AND the output format is identical to pre-change behavior (indented `└─ <name>` lines)

---

### Requirement 6: level-based color for the [level] bracket

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

#### Scenario 6.1: level 0 bracket is cyan

- GIVEN a dep at level `0`
- WHEN `annotate_dep/3` (or equivalent) constructs the annotation string
- THEN the `[0]` segment is wrapped with `UI.cyan/1` ANSI codes

#### Scenario 6.2: level 2 bracket is yellow

- GIVEN a dep at level `2` with `dep_count` of `3` and `deep_count` of `1`
- WHEN the annotation string is constructed
- THEN ANSI-stripped output reads `<name>[2][3][1]`
- AND the `[2]` segment is wrapped with `UI.yellow/1` ANSI codes

#### Scenario 6.3: level 6 cycles back to cyan

- GIVEN a dep at level `6` (i.e. `rem(6, 6) == 0`)
- WHEN the annotation string is constructed
- THEN the `[6]` segment is wrapped with `UI.cyan/1` ANSI codes (same as level 0)

#### Scenario 6.4: [count] and [deep] are rendered dim

- GIVEN any non-leaf dep
- WHEN the annotation string is constructed
- THEN the `[count]` and `[deep]` bracket segments are wrapped with `UI.dim/1` ANSI codes
