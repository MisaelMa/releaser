defmodule Mix.Tasks.Releaser.Bump do
  @shortdoc "Bump version of an app with cascade, pre-release tags, and hooks"
  @moduledoc """
  Bumps the semver version of an app and cascades patch bumps to dependents.

  `[app]` is **optional in single-app projects** (when only one app is
  discovered, the name is inferred). In umbrella / poncho projects with
  multiple apps, the name is required.

  ## Usage

      mix releaser.bump [app] <major|minor|patch>
      mix releaser.bump [app] <major|minor|patch> --mode prerelease --tag dev
      mix releaser.bump [app] --mode prerelease --tag dev        # iterate / promote
      mix releaser.bump [app] release                            # finalize pre-release
      mix releaser.bump [app] 2.0.0                              # explicit version
      mix releaser.bump --list
      mix releaser.bump --all <major|minor|patch>

  ## Modes

  The optional `--mode` flag makes your intent explicit:

    * `prerelease` — open / iterate / promote a pre-release.
      Requires `--tag NAME`. Accepts an optional bump type.

  Without `--mode` the task infers behavior from current state (legacy).

  ## Gitflow workflow example

      # dev branch — open cycle toward 2.0.0
      mix releaser.bump major --mode prerelease --tag dev   # 1.0.0 → 2.0.0-dev.1

      # dev branch — each subsequent merge
      mix releaser.bump --mode prerelease --tag dev         # 2.0.0-dev.1 → 2.0.0-dev.2

      # feature grande
      mix releaser.bump minor --mode prerelease --tag dev   # 2.0.0-dev.3 → 2.1.0-dev.1

      # beta branch — promote
      mix releaser.bump --mode prerelease --tag beta        # 2.1.0-dev.5 → 2.1.0-beta.1

      # main branch — release
      mix releaser.bump release                             # 2.1.0-beta.1 → 2.1.0

      # main branch — hotfix
      mix releaser.bump patch                               # 2.1.0 → 2.1.1

  ## Options

      --mode MODE    Explicit mode. Currently supports `prerelease`.
      --tag TAG      Pre-release tag (dev, beta, rc, alpha, etc.).
      --build BUILD  Build metadata (e.g., 20260420).
      --dry-run      Show what would change without modifying files.
      --no-cascade   Only bump the specified app, skip dependents.
      --no-hooks     Skip pre/post hooks.
      --list         List all apps with current versions.
      --all TYPE     Bump all apps by the given type.
  """

  use Mix.Task

  alias Releaser.{BumpArgs, Version, Workspace, Cascade, FileSync, UI}

  @switches [
    dry_run: :boolean,
    no_cascade: :boolean,
    tag: :string,
    build: :string,
    no_hooks: :boolean,
    mode: :string,
    from_commits: :boolean,
    suggest: :boolean,
    since: :string,
    all: :boolean,
    list_bumped: :boolean
  ]

  @impl Mix.Task
  def run(["--list"]) do
    apps = Workspace.discover()

    apps
    |> Enum.group_by(fn app ->
      case app.path |> Path.split() |> Enum.at(1) do
        nil -> "."
        other -> other
      end
    end)
    |> Enum.sort_by(fn {group, _} -> group end)
    |> Enum.each(fn {group, group_apps} ->
      UI.info("\n#{UI.bright("#{group}/")}")

      Enum.each(group_apps, fn app ->
        v = Version.parse(app.version)
        display = if Version.prerelease?(v), do: UI.cyan(app.version), else: app.version
        short = String.replace(app.name, ~r/^(\w+_)/, "")
        UI.info("  #{String.pad_trailing(short, 22)} #{display}")
      end)
    end)

    UI.info("")
  end

  def run(["--all", bump_type | rest]) do
    {opts, _, _} = OptionParser.parse(rest, switches: @switches)
    apps = Workspace.discover()
    validate_opts!(opts)

    Enum.each(apps, fn app ->
      do_bump(app.name, parse_bump_type(bump_type), opts)
    end)
  end

  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches)

    cond do
      Keyword.get(opts, :list_bumped, false) ->
        list_bumped()

      Keyword.get(opts, :suggest, false) ->
        do_suggest(opts)

      Keyword.get(opts, :from_commits, false) ->
        do_from_commits(positional, opts)

      true ->
        run_manual(positional, opts)
    end
  end

  defp run_manual(positional, opts) do
    apps = Workspace.discover()
    validate_opts!(opts)

    case BumpArgs.resolve_command(positional, apps, opts) do
      {:ok, {:bump, app_name, bump_type}} ->
        do_bump(app_name, bump_type, opts)

      {:ok, {:release, app_name}} ->
        do_release(app_name, opts)

      {:ok, {:explicit, app_name, version_string}} ->
        do_explicit(app_name, version_string, opts)

      {:ok, {:prerelease_only, app_name}} ->
        do_prerelease_iterate(app_name, opts)

      {:error, :usage} ->
        print_usage()

      {:error, {:app_not_found, name}} ->
        UI.error("App '#{name}' not found. Run `mix releaser.bump --list`.")

      {:error, :ambiguous_app} ->
        names = Enum.map_join(apps, ", ", & &1.name)
        UI.error("Multiple apps found: #{names}. Specify app name.")
    end
  end

  # ---------------------------------------------------------------------------
  # Option validation (raises to short-circuit the task)
  # ---------------------------------------------------------------------------

  defp validate_opts!(opts) do
    case BumpArgs.validate_opts(opts) do
      :ok ->
        :ok

      {:error, {:unknown_mode, mode}} ->
        Mix.raise("Unknown --mode #{inspect(mode)}. Supported: prerelease.")

      {:error, :prerelease_requires_tag} ->
        Mix.raise("--mode prerelease requires --tag NAME.")
    end
  end

  # ---------------------------------------------------------------------------
  # Bump actions
  # ---------------------------------------------------------------------------

  defp do_bump(app_name, bump_type, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    cascade? = not Keyword.get(opts, :no_cascade, false)
    tag = Keyword.get(opts, :tag)
    build = Keyword.get(opts, :build)
    no_hooks? = Keyword.get(opts, :no_hooks, false)

    apps = Workspace.discover()

    case Enum.find(apps, &(&1.name == app_name)) do
      nil ->
        UI.error("App '#{app_name}' not found. Run `mix releaser.bump --list`.")

      app ->
        new_version =
          app.version
          |> Version.parse()
          |> Version.bump(bump_type, tag: tag, build: build)
          |> to_string()

        changes = Cascade.plan(app_name, new_version, apps, cascade: cascade?)
        context = build_context(app, bump_type, new_version, changes, apps)

        if not no_hooks?, do: run_pre_hooks(context)
        print_and_apply(changes, dry_run?)
        if not dry_run? and not no_hooks?, do: run_post_hooks(context)
    end
  end

  # --mode prerelease without bump_type: iterate or promote within the tag.
  defp do_prerelease_iterate(app_name, opts) do
    apps = Workspace.discover()
    tag = Keyword.get(opts, :tag)

    case Enum.find(apps, &(&1.name == app_name)) do
      nil ->
        UI.error("App '#{app_name}' not found.")

      app ->
        v = Version.parse(app.version)

        unless Version.prerelease?(v) or tag != v.pre_tag do
          UI.error(
            "#{app_name} is at a stable version (#{app.version}). " <>
              "Specify a bump type (major/minor/patch) to open a pre-release."
          )

          :error
        else
          # Use :patch as a no-op carrier so same-tag iteration increments pre_num
          # and tag-change promotion keeps base.
          do_bump(app_name, :patch, opts)
        end
    end
  end

  defp do_release(app_name, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    cascade? = not Keyword.get(opts, :no_cascade, false)
    no_hooks? = Keyword.get(opts, :no_hooks, false)
    apps = Workspace.discover()

    case Enum.find(apps, &(&1.name == app_name)) do
      nil ->
        UI.error("App '#{app_name}' not found.")

      app ->
        v = Version.parse(app.version)

        if not Version.prerelease?(v) do
          UI.info("#{app_name} is already at a stable version (#{app.version})")
        else
          new_version = v |> Version.release() |> to_string()
          changes = Cascade.plan(app_name, new_version, apps, cascade: cascade?)
          context = build_context(app, :release, new_version, changes, apps)

          if not no_hooks?, do: run_pre_hooks(context)
          print_and_apply(changes, dry_run?)
          if not dry_run? and not no_hooks?, do: run_post_hooks(context)
        end
    end
  end

  defp do_explicit(app_name, version_string, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    cascade? = not Keyword.get(opts, :no_cascade, false)
    no_hooks? = Keyword.get(opts, :no_hooks, false)
    apps = Workspace.discover()

    # Validate version string
    Version.parse(version_string)

    case Enum.find(apps, &(&1.name == app_name)) do
      nil ->
        UI.error("App '#{app_name}' not found.")

      app ->
        new_version = version_string
        changes = Cascade.plan(app_name, new_version, apps, cascade: cascade?)
        context = build_context(app, :explicit, new_version, changes, apps)

        if not no_hooks?, do: run_pre_hooks(context)
        print_and_apply(changes, dry_run?)
        if not dry_run? and not no_hooks?, do: run_post_hooks(context)
    end
  end

  # ---------------------------------------------------------------------------
  # Rendering / hooks
  # ---------------------------------------------------------------------------

  defp print_and_apply(changes, dry_run?) do
    config = Releaser.Config.load()

    UI.info("")
    UI.info(UI.bright("Version changes:"))

    Enum.each(changes, fn %{app: name, old: old, new: new, reason: reason} ->
      UI.info("  #{String.pad_trailing(name, 25)} #{UI.arrow(old, new)}  (#{reason})")
    end)

    if dry_run? do
      UI.info("\n#{UI.cyan("--dry-run: no files modified")}\n")
    else
      Enum.each(changes, fn change ->
        %{path: path, old: old, new: new} = change
        version_form = Map.get(change, :version_form, :literal)
        FileSync.update_mix_version(path, old, new, version_form)
        FileSync.sync_files(path, old, new, config.version_files)
      end)

      UI.info("\n#{UI.green("#{length(changes)} app(s) updated")}\n")
    end
  end

  defp build_context(app, bump_type, new_version, changes, apps) do
    %{
      app: app.name,
      path: app.path,
      old_version: app.version,
      new_version: new_version,
      bump_type: bump_type,
      changes: changes,
      apps: apps
    }
  end

  defp run_pre_hooks(context) do
    config = Releaser.Config.load()

    Enum.each(config.hooks.pre, fn hook_mod ->
      case hook_mod.run(context) do
        :ok -> :ok
        {:error, reason} -> Mix.raise("Pre-hook #{inspect(hook_mod)} failed: #{reason}")
      end
    end)
  end

  defp run_post_hooks(context) do
    config = Releaser.Config.load()

    Enum.each(config.hooks.post, fn hook_mod ->
      case hook_mod.run(context) do
        :ok -> :ok
        {:error, reason} -> UI.error("Post-hook #{inspect(hook_mod)} failed: #{reason}")
      end
    end)
  end

  defp parse_bump_type("major"), do: :major
  defp parse_bump_type("minor"), do: :minor
  defp parse_bump_type("patch"), do: :patch
  defp parse_bump_type(other), do: Mix.raise("Invalid bump type: #{other}")

  # ---------------------------------------------------------------------------
  # Conventional Commits: --suggest / --from-commits / --list-bumped
  # ---------------------------------------------------------------------------

  defp do_suggest(opts) do
    config = Releaser.Config.load()
    ensure_commits_enabled!(config)

    apps = Workspace.discover()
    since = Keyword.get(opts, :since)
    plan = Releaser.Commits.plan(apps: apps, config: config.commits, since: since)

    print_commit_plan(plan, apps, since || Releaser.Commits.detect_last_tag())
  end

  defp do_from_commits(positional, opts) do
    config = Releaser.Config.load()
    ensure_commits_enabled!(config)

    apps = Workspace.discover()
    since = Keyword.get(opts, :since)
    plan = Releaser.Commits.plan(apps: apps, config: config.commits, since: since)

    filtered_plan = filter_plan(plan, positional, apps, opts)

    case filtered_plan do
      [] ->
        UI.info("\n#{UI.cyan("No relevant commits since #{since || "last tag"}. No bump.")}\n")

      entries ->
        Enum.each(entries, fn %{app: name, bump: bump_type} ->
          UI.info("\n#{UI.bright("→ Bumping #{name} (#{bump_type})")}")
          do_bump(name, bump_type, opts)
        end)
    end
  end

  defp list_bumped do
    # Prints one "v<version>" tag per app whose mix.exs version changed vs HEAD~1.
    # Used by CI to know what to tag after `mix releaser.bump --from-commits`.
    apps = Workspace.discover()

    Enum.each(apps, fn app ->
      case previous_version(app) do
        nil -> :ok
        prev when prev == app.version -> :ok
        _ -> IO.puts("v#{app.version}")
      end
    end)
  end

  defp previous_version(app) do
    mix_path = Path.join(app.path, "mix.exs")

    case System.cmd("git", ["show", "HEAD~1:#{mix_path}"], stderr_to_stdout: true) do
      {content, 0} ->
        extract_version_from_string(content)

      {_, _} ->
        nil
    end
  end

  defp extract_version_from_string(content) do
    cond do
      match = Regex.run(~r/version:\s+"([^"]+)"/, content) ->
        [_, v] = match
        v

      match = Regex.run(~r/@version\s+"([^"]+)"/, content) ->
        [_, v] = match
        v

      true ->
        nil
    end
  end

  defp filter_plan(plan, [], _apps, opts) do
    cond do
      Keyword.get(opts, :all, false) -> plan
      match?([_], plan) -> plan
      true -> plan
    end
  end

  defp filter_plan(plan, [app_name | _], _apps, _opts) do
    Enum.filter(plan, &(&1.app == app_name))
  end

  defp print_commit_plan([], _apps, since) do
    UI.info("\n#{UI.cyan("No relevant commits since #{since || "last tag"}.")}\n")
  end

  defp print_commit_plan(plan, apps, since) do
    UI.info("\nAnalyzing commits since #{UI.bright(since || "beginning of history")}...\n")
    UI.info(UI.bright("Apps to bump:"))

    Enum.each(plan, fn %{app: name, bump: bump, commits: commits} ->
      current = apps |> Enum.find(&(&1.name == name)) |> Map.get(:version, "?")

      preview =
        current
        |> Version.parse()
        |> Version.bump(bump, [])
        |> to_string()

      UI.info(
        "  #{String.pad_trailing(name, 20)} #{current} → #{preview}   (#{bump} — #{length(commits)} commit(s))"
      )
    end)

    untouched = Enum.map(apps, & &1.name) -- Enum.map(plan, & &1.app)

    if untouched != [] do
      UI.info("\n#{UI.bright("Apps with no relevant changes:")}")

      Enum.each(untouched, fn name ->
        UI.info("  #{name}")
      end)
    end

    UI.info("\nRun with #{UI.cyan("--from-commits")} to apply.\n")
  end

  defp ensure_commits_enabled!(config) do
    unless config |> Map.get(:commits, %{}) |> Map.get(:enabled, false) do
      Mix.raise("""
      Conventional Commits is not enabled.

      Add to your mix.exs:

          releaser: [
            commits: [enabled: true]
          ]

      See guides/conventional-commits.md for details.
      """)
    end
  end

  defp print_usage do
    UI.error("""
    Usage: mix releaser.bump [app] <major|minor|patch> [--mode prerelease --tag TAG]
           mix releaser.bump [app] --mode prerelease --tag TAG
           mix releaser.bump [app] release
           mix releaser.bump [app] 2.0.0
           mix releaser.bump --list
           mix releaser.bump --all <major|minor|patch>

    `[app]` is optional when only one app is discovered.
    """)
  end
end
