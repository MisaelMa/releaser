defmodule Releaser.Graph do
  @moduledoc """
  Dependency graph building and topological sorting for monorepo apps.

  Builds a directed graph from internal `path:` dependencies and provides
  topological ordering for correct publish order, dependency resolution,
  and cascade planning.

  New annotation helpers (for rendering):
  - `level_map/1` — inverts a `topological_levels/1` result into a `%{name => level}` map.
  - `dep_count/2` — returns the count of direct project-internal deps for a given name.
  - `deep_count/2` — shallow count of a name's direct deps that themselves have at least one dep.
  """

  alias Releaser.App

  @doc """
  Builds a dependency graph from a list of apps.

  Returns a map of `%{app_name => [dependency_names]}`.
  """
  def build(apps) when is_list(apps) do
    Map.new(apps, fn %App{name: name, deps: deps} -> {name, deps} end)
  end

  @doc """
  Returns a map of `%{app_name => [dependent_names]}` (reverse graph).

  For each app, lists which apps depend on it.
  """
  def dependents_of(apps) when is_list(apps) do
    Enum.reduce(apps, %{}, fn %App{name: name, deps: deps}, acc ->
      Enum.reduce(deps, acc, fn dep, acc2 ->
        Map.update(acc2, dep, [name], &[name | &1])
      end)
    end)
  end

  @doc """
  Computes topological levels using Kahn's algorithm.

  Returns `[{level, [app_names]}]` where level 0 has no internal deps,
  level 1 depends only on level 0, etc.
  """
  def topological_levels(apps) when is_list(apps) do
    all_names = MapSet.new(apps, & &1.name)

    # Restrict each app's deps to those present in the input set. Deps that
    # point outside the set (e.g. apps already on Hex when the publisher
    # filters its plan) are external constraints — already satisfied — and
    # must NOT participate in topological ordering. Otherwise a clean DAG
    # gets misreported as circular.
    graph =
      apps
      |> build()
      |> Map.new(fn {name, deps} ->
        {name, Enum.filter(deps, &MapSet.member?(all_names, &1))}
      end)

    do_levels(all_names, graph, 0, [])
  end

  defp do_levels(remaining, graph, level, acc) do
    if MapSet.size(remaining) == 0 do
      Enum.reverse(acc)
    else
      placed = placed_set(acc)

      ready =
        remaining
        |> MapSet.to_list()
        |> Enum.filter(fn name ->
          deps = Map.get(graph, name, [])
          Enum.all?(deps, &MapSet.member?(placed, &1))
        end)
        |> Enum.sort()

      if ready == [] do
        cycle = remaining |> MapSet.to_list() |> Enum.sort()

        Mix.raise("""
        Circular dependency detected between apps:

            #{Enum.join(cycle, " ↔ ")}

        Hex packages cannot be published with circular path: deps. Inspect
        each app's mix.exs and break the cycle (e.g. extract shared code
        into a third app, or invert one of the dependencies).
        """)
      else
        new_remaining = MapSet.difference(remaining, MapSet.new(ready))
        do_levels(new_remaining, graph, level + 1, [{level, ready} | acc])
      end
    end
  end

  defp placed_set(levels) do
    levels
    |> Enum.flat_map(fn {_level, names} -> names end)
    |> MapSet.new()
  end

  @doc """
  Resolves transitive dependencies for a list of app names.

  Returns a MapSet of all apps that need to be included (the requested
  apps plus all their transitive dependencies).
  """
  def transitive_deps(app_names, graph) when is_list(app_names) and is_map(graph) do
    Enum.reduce(app_names, MapSet.new(), fn name, acc ->
      collect_transitive(name, graph, acc)
    end)
  end

  defp collect_transitive(name, graph, visited) do
    if MapSet.member?(visited, name) do
      visited
    else
      visited = MapSet.put(visited, name)

      Map.get(graph, name, [])
      |> Enum.reduce(visited, fn dep, acc -> collect_transitive(dep, graph, acc) end)
    end
  end

  @doc """
  Resolves transitive dependents for a list of app names (reverse direction).

  Given an app, returns all apps that depend on it recursively (upstream).
  For example, if `cfdi_xml` depends on `cfdi_csd`, then `cfdi_xml` is a
  transitive dependent of `cfdi_csd`.

  This is the inverse of `transitive_deps/2`.
  """
  def transitive_dependents(app_names, apps) when is_list(app_names) and is_list(apps) do
    dep_map = dependents_of(apps)

    Enum.reduce(app_names, MapSet.new(app_names), fn name, acc ->
      collect_dependents(name, dep_map, acc)
    end)
  end

  defp collect_dependents(name, dep_map, visited) do
    dependents = Map.get(dep_map, name, [])

    Enum.reduce(dependents, visited, fn dep, acc ->
      if MapSet.member?(acc, dep) do
        acc
      else
        acc
        |> MapSet.put(dep)
        |> then(&collect_dependents(dep, dep_map, &1))
      end
    end)
  end

  @type name :: String.t()
  @type graph :: %{name() => [name()]}
  @type levels :: [{non_neg_integer(), [name()]}]

  @doc """
  Inverts the `topological_levels/1` result into a name-keyed map for O(1) level lookups.

  ## Examples

      iex> Graph.level_map([{0, ["c", "d"]}, {1, ["b"]}, {2, ["a"]}])
      %{"a" => 2, "b" => 1, "c" => 0, "d" => 0}

      iex> Graph.level_map([])
      %{}
  """
  @spec level_map(levels()) :: %{name() => non_neg_integer()}
  def level_map(levels) when is_list(levels) do
    Enum.reduce(levels, %{}, fn {level, names}, acc ->
      Enum.reduce(names, acc, fn name, a -> Map.put(a, name, level) end)
    end)
  end

  @doc """
  Returns the count of direct project-internal deps for a given app name.

  Returns `0` for unknown names (not present in the graph).

  ## Examples

      iex> Graph.dep_count("a", %{"a" => ["b", "c"], "b" => ["c"], "c" => []})
      2

      iex> Graph.dep_count("z", %{"a" => ["b"]})
      0
  """
  @spec dep_count(name(), graph()) :: non_neg_integer()
  def dep_count(name, graph) when is_binary(name) and is_map(graph) do
    Map.get(graph, name, []) |> length()
  end

  @doc """
  Shallow count of `name`'s direct deps that themselves have at least one project-internal dep.

  SHALLOW count, NOT a recursive depth metric. For a chain `a→b→c` where `c` has no deps:
  - `deep_count("a", graph)` is `1` (b has deps)
  - `deep_count("b", graph)` is `0` (c has no deps)

  See ADR D4 in the design document.

  Returns `0` for leaves and unknown names.

  ## Examples

      iex> graph = %{"a" => ["b"], "b" => ["c"], "c" => []}
      iex> Graph.deep_count("a", graph)
      1
      iex> Graph.deep_count("b", graph)
      0
  """
  @spec deep_count(name(), graph()) :: non_neg_integer()
  def deep_count(name, graph) when is_binary(name) and is_map(graph) do
    Map.get(graph, name, [])
    |> Enum.count(fn dep -> Map.get(graph, dep, []) != [] end)
  end

  @doc """
  Filters topological levels to only include the specified apps.
  Removes empty levels.
  """
  def filter_levels(levels, required_apps) when is_list(levels) do
    levels
    |> Enum.map(fn {level, names} ->
      {level, Enum.filter(names, &MapSet.member?(required_apps, &1))}
    end)
    |> Enum.reject(fn {_level, names} -> names == [] end)
  end
end
