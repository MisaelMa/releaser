# Spec: Releaser.Graph

## Overview

Pure dataflow module for dependency graph analysis and manipulation.

---

## Requirements: level_map/1

`Releaser.Graph.level_map/1` MUST accept the `[{level, [name]}]` list returned by `topological_levels/1` and return `%{name => level}` so that any caller can look up a dep's level in O(1).

### Scenario 1.1: happy path — multi-level input

- GIVEN a levels list `[{0, ["c", "d"]}, {1, ["b"]}, {2, ["a"]}]`
- WHEN `Graph.level_map/1` is called with that list
- THEN the result is `%{"a" => 2, "b" => 1, "c" => 0, "d" => 0}`

### Scenario 1.2: empty input returns empty map

- GIVEN an empty list `[]`
- WHEN `Graph.level_map/1` is called
- THEN the result is `%{}`

### Scenario 1.3: single level (all leaves)

- GIVEN a levels list `[{0, ["x", "y"]}]`
- WHEN `Graph.level_map/1` is called
- THEN the result is `%{"x" => 0, "y" => 0}`

---

## Requirements: dep_count/2

`Releaser.Graph.dep_count/2` MUST accept a `name` (string) and a `graph` map (`%{name => [dep_name]}`) and return the integer count of the list at `graph[name]`. It MUST return `0` for any name not present in the graph.

### Scenario 2.1: known name with deps

- GIVEN a graph `%{"a" => ["b", "c"], "b" => ["c"], "c" => []}`
- WHEN `Graph.dep_count("a", graph)` is called
- THEN the result is `2`

### Scenario 2.2: known name with no deps

- GIVEN a graph `%{"a" => ["b"], "b" => []}`
- WHEN `Graph.dep_count("b", graph)` is called
- THEN the result is `0`

### Scenario 2.3: unknown name returns 0

- GIVEN a graph `%{"a" => ["b"]}`
- WHEN `Graph.dep_count("z", graph)` is called
- THEN the result is `0`

---

## Requirements: deep_count/2

`Releaser.Graph.deep_count/2` MUST accept a `name` (string) and a `graph` map and return a **shallow** integer count of how many of `name`'s direct deps themselves have at least one project-internal dep listed in the graph. It MUST NOT recurse further than one level beyond `name`'s direct deps. It MUST return `0` for leaves and for unknown names.

NOTE: `deep_count` is explicitly a shallow metric, not a recursive depth. For a chain `a → b → c` where `c` has no deps, `deep_count("a", graph)` is `1` (only `b` qualifies — it has `c` as a dep), NOT `2`.

### Scenario 3.1: shallow semantics — 3-node chain

- GIVEN a graph `%{"a" => ["b"], "b" => ["c"], "c" => []}`
- WHEN `Graph.deep_count("a", graph)` is called
- THEN the result is `1` (b has deps; c does not — c is not counted because it is not a direct dep of a)
- AND `Graph.deep_count("b", graph)` is `0` (c is a direct dep of b, but c has no deps, so b has zero non-leaf direct deps)

### Scenario 3.2: leaf node returns 0

- GIVEN a graph `%{"a" => ["b"], "b" => []}`
- WHEN `Graph.deep_count("b", graph)` is called
- THEN the result is `0`

### Scenario 3.3: unknown name returns 0

- GIVEN a graph `%{"a" => ["b"]}`
- WHEN `Graph.deep_count("z", graph)` is called
- THEN the result is `0`

### Scenario 3.4: multiple qualifying direct deps

- GIVEN a graph `%{"root" => ["x", "y", "z"], "x" => ["a"], "y" => ["b"], "z" => []}`
- WHEN `Graph.deep_count("root", graph)` is called
- THEN the result is `2` (x and y each have deps; z has none)
