# Exploration: annotate-graph-deps

## Current State

`mix releaser.graph` (no-arg form) iterates `levels` from `Graph.topological_levels/1` and for each app it prints:
- `UI.green(name)` + `UI.yellow("v#{version}")` on one line
- `UI.dim("└─ depends on: <comma-joined yellow dep names>")` on a second line only when `deps != []`

The rendering loop (lines 27-55 of `releaser.graph.ex`) holds BOTH `levels` and `graph` in scope (built on lines 19-20), so the data is available — but the dep list is printed as plain coloured strings, with no annotation.

Key data flows:
- `levels` is `[{level_integer, [name_string]}]` (Kahn result)
- `graph` is `%{name => [dep_name]}` (direct project-internal deps)
- `apps` is `[%App{}]` (filtered to path-deps only by `Workspace.discover/0`)

The topological level of each dep name is NOT directly accessible at render time — `levels` must be inverted into a `%{name => level}` map.

## Affected Areas

- `lib/mix/tasks/releaser.graph.ex` — rendering loop (lines 37-47), dep string construction (line 44). Primary change surface.
- `lib/releaser/graph.ex` — needs 3 new pure helpers (`level_map/1`, `dep_count/2`, `deep_count/2`).
- `lib/releaser/ui.ex` — needs new color helpers (`magenta/1`, `blue/1`).
- `test/releaser/graph_test.exs` — needs tests for the 3 new helpers.
- No test file exists yet for `Mix.Tasks.Releaser.Graph` — rendering side currently untested.

## Detailed Findings

### `App.deps` already filtered to project-internal

`Workspace.discover/0` resolves only deps whose names appear in the discovered app set. `App.deps` is a `[String.t()]` of project-internal names only. No additional filtering needed.

### New `Releaser.Graph` helpers

```elixir
@spec level_map([{integer, [String.t()]}]) :: %{String.t() => integer}
def level_map(levels) when is_list(levels) do
  Enum.reduce(levels, %{}, fn {level, names}, acc ->
    Enum.reduce(names, acc, fn name, a -> Map.put(a, name, level) end)
  end)
end

@spec dep_count(String.t(), %{String.t() => [String.t()]}) :: integer
def dep_count(name, graph) when is_binary(name) and is_map(graph) do
  Map.get(graph, name, []) |> length()
end

@spec deep_count(String.t(), %{String.t() => [String.t()]}) :: integer
def deep_count(name, graph) when is_binary(name) and is_map(graph) do
  Map.get(graph, name, [])
  |> Enum.count(fn dep -> Map.get(graph, dep, []) != [] end)
end
```

`deep_count/2` is **shallow** (one-level lookahead), not recursive — it counts how many of `name`'s direct deps are themselves non-leaf. This matches the spec ("count of [count] deps that themselves have project-internal subdeps").

### Clean output rule

When `level == 0 AND dep_count == 0 AND deep_count == 0` (true leaf), print just the name. By definition this fires exactly for level-0 nodes; level ≥ 1 nodes always have `dep_count ≥ 1`.

### Color palette for `[level]` bracket

| Level | Color | UI function |
|-------|-------|-------------|
| 0 | cyan | exists (`cyan/1`) |
| 1 | green | exists (`green/1`) |
| 2 | yellow | exists (`yellow/1`) |
| 3 | magenta | NEW: `magenta/1` |
| 4 | red | exists (`red/1`) |
| 5 | blue | NEW: `blue/1` |
| 6+ | cycle | `rem(level, 6)` wraps |

### Annotation rendering (private to task)

```elixir
defp level_color(text, level) do
  case rem(level, 6) do
    0 -> UI.cyan(text)
    1 -> UI.green(text)
    2 -> UI.yellow(text)
    3 -> UI.magenta(text)
    4 -> UI.red(text)
    5 -> UI.blue(text)
  end
end

defp annotate_dep(dep_name, graph, lmap) do
  lvl = Map.get(lmap, dep_name, 0)
  cnt = Graph.dep_count(dep_name, graph)
  dep = Graph.deep_count(dep_name, graph)

  suffix =
    if lvl == 0 and cnt == 0 and dep == 0 do
      ""
    else
      level_color("[#{lvl}]", lvl) <> UI.dim("[#{cnt}][#{dep}]")
    end

  UI.yellow(dep_name) <> suffix
end
```

### Scope: `mix releaser.graph <app>` form NOT annotated

The `run([app_name])` branch shows a dependents tree (reverse graph). User's example only showed the levels view; semantic differences and added complexity → out of scope for this change.

## Approaches

1. **Minimal — helpers in Graph, rendering in task** (RECOMMENDED)
   - 3 pure helpers on `Graph`, 2 private rendering helpers in task, 2 new color helpers on `UI`
   - Pros: clean separation; pure helpers independently testable; minimal surface
2. **Richer — `annotate/3` on Graph returning structured data**
   - Cons: mixes display concerns into pure graph module; over-engineering
3. **Full — annotate `<app>` form too**
   - Cons: broader surface; out of user-stated scope

## Recommendation

Approach 1.

## Risks

- **No-color terminals**: ANSI codes emitted unconditionally — pre-existing across `Releaser.UI`, not introduced here, but tests must strip ANSI before assertions (`IO.ANSI` regex or strip helper).
- **Mix task currently untested**: New rendering logic + Strict TDD → need first test using `Mix.shell(Mix.Shell.Process)` capture pattern.
- **`deep_count` naming**: shallow one-level count; the proposal should clarify the doc string ("not recursive").
- **Performance**: `deep_count` is O(direct_deps), trivial for real graphs.

## Ready for Proposal

Yes.
