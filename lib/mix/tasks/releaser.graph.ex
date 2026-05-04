defmodule Mix.Tasks.Releaser.Graph do
  @shortdoc "Show dependency graph of monorepo apps"
  @moduledoc """
  Displays the dependency graph of all apps in the workspace.

  ## Usage

      mix releaser.graph                    # compact (default)
      mix releaser.graph --detailed         # multiline metadata per app
      mix releaser.graph -d                 # alias for --detailed
      mix releaser.graph --hex              # also query Hex for publish status
      mix releaser.graph -d --hex           # combine both
      mix releaser.graph <app>              # show dependents of an app

  ## Output modes

  ### Compact (default)

  Each app fits on one line with inline badges:

      sat_auth v1.0.1 [publish: ✓] [hex: ahead] [@version]
      └─ depends on: cfdi_certificados[0][0][0]

  Badges:

  - `[publish: ✓/✗]` — always shown; `✓` when the app has `releaser: [publish: true]`.
  - `[hex: ...]` — only with `--hex`. Possible values: `ahead`, `published`, `unpub`, `pre`.
  - `[@version]` — only when the app declares `@version` (vs. literal `version: "..."`).

  ### Detailed

  Each app expands to multiple `├─` / `└─` branches:

      sat_auth v1.0.1
      ├─ depends on: cfdi_certificados[0][0][0]
      ├─ publish: yes
      ├─ hex: ahead (local v1.0.1, remote v1.0.0)
      ├─ version form: @version
      └─ path: apps/sat_auth

  ## Annotation format (deps)

  In both modes, each project-internal dep listed under `depends on:` is rendered
  as `name[level][count][deep]`:

  - `[level]` — topological level of the dep, colored by palette (cycles every 6).
  - `[count]` — number of direct project-internal deps the dep itself has.
  - `[deep]`  — shallow count of those deps that themselves have further deps.

  True leaves (level 0, count 0, deep 0) are rendered as bare names with no brackets.
  The `<app>` dependents-tree form is not annotated.
  """

  use Mix.Task

  alias Releaser.{Graph, Workspace, UI, HexStatus}

  @switches [detailed: :boolean, hex: :boolean]
  @aliases [d: :detailed]

  @impl Mix.Task
  def run(argv) do
    {opts, args, _invalid} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    case args do
      [] ->
        apps = Workspace.discover()
        opts = maybe_load_hex(opts, apps)
        render_graph(apps, opts)

      [app_name] ->
        apps = Workspace.discover()
        dependents_map = Graph.dependents_of(apps)

        UI.info("\n#{UI.bright("Dependents of #{app_name}:")}")
        print_tree(app_name, dependents_map, 1, MapSet.new())
        UI.info("")

      _ ->
        UI.error("Usage: mix releaser.graph [--detailed|-d] [--hex] [app_name]")
    end
  end

  defp maybe_load_hex(opts, apps) do
    if Keyword.get(opts, :hex, false) do
      hex_map =
        HexStatus.check_apps(apps)
        |> Map.new(fn %{app: name, local: l, hex: h, status: s} ->
          {name, %{local: l, hex: h, status: s}}
        end)

      Keyword.put(opts, :hex_map, hex_map)
    else
      opts
    end
  end

  @doc false
  def render_graph(apps), do: render_graph(apps, [])

  @doc false
  def render_graph(apps, opts) when is_list(opts) do
    detailed? = Keyword.get(opts, :detailed, false)
    hex? = Keyword.get(opts, :hex, false)
    hex_map = Keyword.get(opts, :hex_map, %{})

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

        if detailed? do
          render_app_detailed(app, deps, graph, lmap, hex?, hex_map)
        else
          render_app_compact(app, deps, graph, lmap, hex?, hex_map)
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
    publishable = Enum.count(apps, & &1.publish)

    UI.info("\n#{UI.bright("Summary:")}")
    UI.info("  Total apps:          #{total}")
    UI.info("  Levels:              #{total_levels}")
    UI.info("  Apps with path deps: #{with_deps}")
    UI.info("  Publishable apps:    #{publishable}")
    UI.info("  Publish order:       level 0 → level #{total_levels - 1}")
    UI.info("")
  end

  defp render_app_compact(app, deps, graph, lmap, hex?, hex_map) do
    badges = compact_badges(app, hex?, hex_map)

    UI.info(
      "#{UI.cyan("│")}   #{UI.green(app.name)} #{UI.yellow("v#{app.version}")}#{badges}"
    )

    if deps != [] do
      dep_str = Enum.map(deps, &annotate_dep(&1, graph, lmap)) |> Enum.join(", ")
      UI.info("#{UI.cyan("│")}   #{UI.dim("└─ depends on: #{dep_str}")}")
    end
  end

  defp compact_badges(app, hex?, hex_map) do
    badges =
      [
        publish_badge_compact(app.publish),
        if(hex?, do: hex_badge_compact(Map.get(hex_map, app.name))),
        if(app.version_form == :attribute, do: UI.dim("[@version]"))
      ]
      |> Enum.reject(&is_nil/1)

    case badges do
      [] -> ""
      list -> " " <> Enum.join(list, " ")
    end
  end

  defp publish_badge_compact(true), do: UI.green("[publish: ✓]")
  defp publish_badge_compact(_), do: UI.dim("[publish: ✗]")

  defp hex_badge_compact(nil), do: UI.dim("[hex: ?]")
  defp hex_badge_compact(%{status: :ahead}), do: UI.green("[hex: ahead]")
  defp hex_badge_compact(%{status: :published}), do: UI.dim("[hex: published]")
  defp hex_badge_compact(%{status: :unpublished}), do: UI.yellow("[hex: unpub]")
  defp hex_badge_compact(%{status: :prerelease}), do: UI.magenta("[hex: pre]")

  defp render_app_detailed(app, deps, graph, lmap, hex?, hex_map) do
    UI.info("#{UI.cyan("│")}   #{UI.green(app.name)} #{UI.yellow("v#{app.version}")}")

    lines =
      [
        deps_line_detailed(deps, graph, lmap),
        {"publish", publish_text_detailed(app.publish)},
        if(hex?, do: {"hex", hex_text_detailed(Map.get(hex_map, app.name))}),
        if(app.version_form == :attribute, do: {"version form", UI.dim("@version")}),
        {"path", UI.dim(app.path)}
      ]
      |> Enum.reject(&is_nil/1)

    total = length(lines)

    Enum.with_index(lines, 1)
    |> Enum.each(fn {{label, value}, idx} ->
      branch = if idx == total, do: "└─", else: "├─"
      UI.info("#{UI.cyan("│")}   #{UI.dim(branch)} #{label}: #{value}")
    end)
  end

  defp deps_line_detailed([], _graph, _lmap), do: nil

  defp deps_line_detailed(deps, graph, lmap) do
    dep_str = Enum.map(deps, &annotate_dep(&1, graph, lmap)) |> Enum.join(", ")
    {"depends on", dep_str}
  end

  defp publish_text_detailed(true), do: UI.green("yes")
  defp publish_text_detailed(_), do: UI.dim("no")

  defp hex_text_detailed(nil), do: UI.dim("unknown")

  defp hex_text_detailed(%{status: :ahead, local: l, hex: h}),
    do: UI.green("ahead") <> UI.dim(" (local v#{l}, remote v#{h})")

  defp hex_text_detailed(%{status: :published, hex: h}),
    do: UI.dim("published (v#{h})")

  defp hex_text_detailed(%{status: :unpublished}), do: UI.yellow("unpublished")

  defp hex_text_detailed(%{status: :prerelease, local: l}),
    do: UI.magenta("prerelease (v#{l})")

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
