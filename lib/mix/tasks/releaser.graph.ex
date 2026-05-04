defmodule Mix.Tasks.Releaser.Graph do
  @shortdoc "Show dependency graph of monorepo apps"
  @moduledoc """
  Displays the dependency graph of all apps in the workspace.

  ## Usage

      mix releaser.graph              # full graph with levels
      mix releaser.graph <app>        # show dependents of an app

  ## Annotation format

  In the levels view, each project-internal dep is rendered as:

      name[level][count][deep]

  Where:
  - `[level]` — topological level of the dep, colored by palette (cycles every 6).
  - `[count]` — number of direct project-internal deps the dep itself has.
  - `[deep]`  — shallow count of those deps that themselves have further deps.

  True leaves (level 0, count 0, deep 0) are rendered as bare names with no brackets.
  The `<app>` dependents-tree form is not annotated.
  """

  use Mix.Task

  alias Releaser.{Graph, Workspace, UI}

  @impl Mix.Task
  def run([]) do
    apps = Workspace.discover()
    render_graph(apps)
  end

  def run([app_name]) do
    apps = Workspace.discover()
    dependents_map = Graph.dependents_of(apps)

    UI.info("\n#{UI.bright("Dependents of #{app_name}:")}")
    print_tree(app_name, dependents_map, 1, MapSet.new())
    UI.info("")
  end

  def run(_) do
    UI.error("Usage: mix releaser.graph [app_name]")
  end

  @doc false
  def render_graph(apps) do
    levels = Graph.topological_levels(apps)
    graph = Graph.build(apps)
    lmap = Graph.level_map(levels)
    total_levels = length(levels)

    UI.info("\n#{UI.bright("╔══════════════════════════════════════════════════╗")}")
    UI.info("#{UI.bright("║           Dependency Graph                       ║")}")
    UI.info("#{UI.bright("╚══════════════════════════════════════════════════╝")}\n")

    Enum.each(levels, fn {level, app_names} ->
      label =
        case level do
          0 -> "Level 0  (no internal deps)"
          _ -> "Level #{level}"
        end

      UI.info(UI.cyan("┌── #{label} ──┐"))
      UI.info(UI.cyan("│"))

      Enum.each(app_names, fn name ->
        app = Enum.find(apps, &(&1.name == name))
        deps = Map.get(graph, name, [])

        UI.info("#{UI.cyan("│")}   #{UI.green(name)} #{UI.yellow("v#{app.version}")}")

        if deps != [] do
          dep_str = Enum.map(deps, &annotate_dep(&1, graph, lmap)) |> Enum.join(", ")
          UI.info("#{UI.cyan("│")}   #{UI.dim("└─ depends on: #{dep_str}")}")
        end
      end)

      UI.info(UI.cyan("│"))

      if level < total_levels - 1 do
        UI.info("#{UI.cyan("│")}       #{UI.bright("▼")}")
        UI.info(UI.cyan("│"))
      end
    end)

    UI.info(UI.cyan("└── end ──┘"))

    total = Enum.reduce(levels, 0, fn {_, names}, acc -> acc + length(names) end)
    with_deps = Enum.count(apps, &(&1.deps != []))

    UI.info("\n#{UI.bright("Summary:")}")
    UI.info("  Total apps:         #{total}")
    UI.info("  Levels:             #{total_levels}")
    UI.info("  Apps with path deps: #{with_deps}")
    UI.info("  Publish order:      level 0 → level #{total_levels - 1}")
    UI.info("")
  end

  @spec level_color(String.t(), non_neg_integer()) :: String.t()
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

  @spec annotate_dep(String.t(), Releaser.Graph.graph(), %{String.t() => non_neg_integer()}) ::
          String.t()
  defp annotate_dep(dep_name, graph, lmap) do
    lvl = Map.get(lmap, dep_name, 0)
    cnt = Graph.dep_count(dep_name, graph)
    dpc = Graph.deep_count(dep_name, graph)

    if lvl == 0 and cnt == 0 and dpc == 0 do
      UI.yellow(dep_name)
    else
      UI.yellow(dep_name) <> level_color("[#{lvl}]", lvl) <> UI.dim("[#{cnt}][#{dpc}]")
    end
  end

  defp print_tree(app_name, dep_map, depth, visited) do
    dependents = Map.get(dep_map, app_name, [])
    indent = String.duplicate("  ", depth)

    Enum.each(dependents, fn dep ->
      if MapSet.member?(visited, dep) do
        UI.info("#{indent}└─ #{dep} (circular, skip)")
      else
        UI.info("#{indent}└─ #{dep}")
        print_tree(dep, dep_map, depth + 1, MapSet.put(visited, dep))
      end
    end)
  end
end
