defmodule Releaser.Publisher do
  @moduledoc """
  Orchestrates publishing multiple apps to Hex in topological order.

  For each app (in dependency order):
  1. Backs up the original `mix.exs`
  2. Replaces `path:` deps with their published Hex versions (`~> X.Y`)
  3. Injects `package/0` metadata if missing
  4. Runs `mix hex.publish --yes`
  5. Restores the original `mix.exs` (always, even on failure)
  """

  alias Releaser.{Graph, Version, Workspace, UI}

  @doc """
  Plans the publish order and returns a list of levels with app info.

  Does not modify anything. Filters out apps whose local version is
  already on Hex (`status == :published`), so publish is idempotent.

  Returns a map with:
    * `:levels` — topological levels after filtering (only apps that need publishing)
    * `:apps` — publishable apps with cleaned internal deps
    * `:graph` — dep graph
    * `:skipped` — apps filtered out because they're already on Hex (or pre-release).
      Each entry is `%{app: name, local: v, hex: v, reason: :already_published | :prerelease}`.
  """
  def plan(opts \\ []) do
    all_apps = Workspace.discover(opts)
    # Only publishable apps participate in the publish plan
    publishable_apps = Enum.filter(all_apps, & &1.publish)
    # Filter deps to only reference other publishable apps
    publishable_names = MapSet.new(publishable_apps, & &1.name)

    publishable_apps_filtered =
      Enum.map(publishable_apps, fn app ->
        %{app | deps: Enum.filter(app.deps, &MapSet.member?(publishable_names, &1))}
      end)

    # Check Hex status for each app (unless caller passes :statuses for tests).
    statuses =
      Keyword.get_lazy(opts, :statuses, fn ->
        compute_statuses(publishable_apps_filtered)
      end)

    {to_publish, skipped} =
      Enum.split_with(publishable_apps_filtered, fn app ->
        case Map.get(statuses, app.name) do
          %{status: :ahead} -> true
          %{status: :unpublished} -> true
          # :published (local <= hex) → skip
          # :prerelease → skip (we don't auto-publish pre-releases)
          _ -> false
        end
      end)

    skipped_entries =
      Enum.map(skipped, fn app ->
        info = Map.get(statuses, app.name, %{local: app.version, hex: nil, status: :unknown})

        reason =
          case info.status do
            :prerelease -> :prerelease
            _ -> :already_published
          end

        %{app: app.name, local: info.local, hex: info.hex, reason: reason}
      end)

    levels = Graph.topological_levels(to_publish)
    graph = Graph.build(to_publish)

    only = Keyword.get(opts, :only)

    levels =
      if only do
        # Resolve dependents (upstream) — who depends on the apps I changed?
        required = Graph.transitive_dependents(only, to_publish)
        Graph.filter_levels(levels, required)
      else
        levels
      end

    %{
      levels: levels,
      apps: to_publish,
      graph: graph,
      skipped: skipped_entries
    }
  end

  defp compute_statuses(apps) do
    Enum.into(apps, %{}, fn app ->
      hex_version = hex_version_for(app.name)
      status = compute_status(app.version, hex_version)

      {app.name,
       %{
         local: app.version,
         hex: hex_version,
         status: status
       }}
    end)
  end

  defp hex_version_for(app_name) do
    # Re-uses HexStatus internals by calling it per-app. We go through
    # `System.cmd/3` directly to avoid scanning the whole workspace.
    case System.cmd("mix", ["hex.info", app_name], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/Releases:\s*(\S+)/, output) do
          [_, versions_str] ->
            versions_str
            |> String.split(",")
            |> List.first()
            |> String.trim()

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp compute_status(_local, nil), do: :unpublished

  defp compute_status(local, hex) do
    v = Version.parse(local)

    if Version.prerelease?(v) do
      :prerelease
    else
      case Elixir.Version.compare(local, hex) do
        :gt -> :ahead
        :eq -> :published
        :lt -> :published
      end
    end
  end

  @doc """
  Executes the publish flow.
  """
  def execute(opts \\ []) do
    %{levels: levels, apps: apps, graph: graph} = plan(opts)
    bump_type = Keyword.get(opts, :bump)
    org = Keyword.get(opts, :org)
    config = Releaser.Config.load()
    pkg_defaults = config.publisher.package_defaults

    ensure_hex_auth!()

    published = %{}
    backups = []

    {_pub, backups} =
      Enum.reduce(levels, {published, backups}, fn {level, app_names}, {pub, bkps} ->
        UI.info("\n#{UI.bright("--- Publishing level #{level} ---")}\n")

        Enum.reduce(app_names, {pub, bkps}, fn name, {pub_acc, bkp_acc} ->
          app = Enum.find(apps, &(&1.name == name))
          mix_path = Path.join(app.path, "mix.exs")
          original = File.read!(mix_path)
          bkp_acc = [{mix_path, original} | bkp_acc]

          # 1. Bump version if requested
          new_version = maybe_bump(app.version, bump_type)
          content = replace_version(original, app.version, new_version, app.version_form)

          # 2. Replace path deps with hex versions
          deps = Map.get(graph, name, [])

          content =
            Enum.reduce(deps, content, fn dep, c ->
              dep_version = Map.get(pub_acc, dep, find_version(apps, dep))
              replace_path_dep(c, dep, dep_version)
            end)

          # 3. Inject package() if not present
          content = ensure_package_config(content, pkg_defaults)

          # 4. Write modified mix.exs
          File.write!(mix_path, content)

          # 5. Publish (streaming output so the user sees progress live)
          UI.info("Publishing #{name} v#{new_version}...")
          org_args = if org, do: ["--organization", org], else: []

          case run_streaming("mix", ["hex.publish", "--yes"] ++ org_args, app.path) do
            0 ->
              UI.info("  #{UI.green("#{name} v#{new_version} published!")}")
              {Map.put(pub_acc, name, new_version), bkp_acc}

            code ->
              UI.error("\nFailed to publish #{name} (exit #{code}).")
              UI.info("\n#{UI.yellow("Restoring all mix.exs files...")}")
              restore(bkp_acc)
              Mix.raise("Publish failed for #{name}. All mix.exs files have been restored.")
          end
        end)
      end)

    UI.info("\n#{UI.bright("Restoring mix.exs files to path: deps...")}")
    restore(backups)
    UI.info("#{UI.green("All done! #{length(backups)} package(s) published.")}\n")
  end

  @doc "Restores backed-up mix.exs files."
  def restore(backups) do
    Enum.each(backups, fn {path, content} -> File.write!(path, content) end)
  end

  # --- mix.exs manipulation ---

  def replace_path_dep(content, dep_name, dep_version) do
    v = Version.parse(dep_version)
    mm = Version.major_minor(v)

    Regex.replace(
      ~r/\{:#{dep_name},\s*path:\s*"[^"]*"\}/,
      content,
      "{:#{dep_name}, \"~> #{mm}\"}"
    )
  end

  def ensure_package_config(content, pkg_defaults) do
    if String.contains?(content, "package:") or String.contains?(content, "package()") do
      content
    else
      licenses = inspect(Map.get(pkg_defaults, :licenses, ["MIT"]))
      links = inspect(Map.get(pkg_defaults, :links, %{}))
      files = inspect(Map.get(pkg_defaults, :files, ~w(lib mix.exs README.md LICENSE)))

      package_fn = """

        defp package do
          [
            licenses: #{licenses},
            links: #{links},
            files: #{files}
          ]
        end
      """

      content
      |> String.replace(
        ~r/(deps:\s*deps\(\))(\s*\n)/,
        "\\1,\n      package: package()\\2"
      )
      |> String.replace(
        ~r/(  defp deps do)/,
        String.trim_trailing(package_fn) <> "\n\n\\1"
      )
    end
  end

  defp replace_version(content, old_v, new_v, _form) when old_v == new_v, do: content

  defp replace_version(content, old_v, new_v, :attribute) do
    String.replace(content, ~s(@version "#{old_v}"), ~s(@version "#{new_v}"), global: false)
  end

  defp replace_version(content, old_v, new_v, _form) do
    String.replace(content, ~s(version: "#{old_v}"), ~s(version: "#{new_v}"), global: false)
  end

  defp maybe_bump(version, nil), do: version

  defp maybe_bump(version, bump_type) do
    version |> Version.parse() |> Version.release() |> Version.bump(bump_type) |> to_string()
  end

  defp find_version(apps, name) do
    case Enum.find(apps, &(&1.name == name)) do
      %{version: v} -> v
      nil -> "0.0.0"
    end
  end

  # ---------------------------------------------------------------------------
  # Hex auth + process streaming
  # ---------------------------------------------------------------------------

  # Verifies that Hex can authenticate, either via HEX_API_KEY in the env
  # or via `mix hex.user whoami` (persisted local auth).
  defp ensure_hex_auth! do
    cond do
      System.get_env("HEX_API_KEY") not in [nil, ""] ->
        :ok

      hex_user_authenticated?() ->
        :ok

      true ->
        Mix.raise("""
        Hex authentication not configured.

        Pick one of:

          1. Persisted local auth (interactive):
             mix hex.user auth

          2. Environment variable (CI-friendly):
             HEX_API_KEY=<key> mix releaser.publish

        Get a key at https://hex.pm/dashboard/keys
        """)
    end
  end

  defp hex_user_authenticated? do
    # Run `mix hex.user whoami` with stdin closed (via Port without :use_stdio)
    # so Hex cannot prompt interactively. We only want the authenticated-or-not
    # status; any prompt means not authenticated.
    port =
      Port.open(
        {:spawn_executable, System.find_executable("mix")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:args, ["hex.user", "whoami"]}
        ]
      )

    {output, status} = collect_port_output(port, "", 5_000)

    status == 0 and
      String.trim(output) != "" and
      not String.contains?(output, "No authenticated user") and
      not String.contains?(output, "authenticate now?")
  rescue
    _ -> false
  end

  defp collect_port_output(port, acc, timeout) do
    receive do
      {^port, {:data, chunk}} when is_binary(chunk) ->
        collect_port_output(port, acc <> chunk, timeout)

      {^port, {:exit_status, status}} ->
        {acc, status}
    after
      timeout ->
        # Anything that hangs longer than 5s is treated as "not authenticated".
        send(self(), {port, {:exit_status, 1}})
        Port.close(port)
        {acc, 1}
    end
  end

  # Runs a command in `cwd` and streams stdout/stderr to the parent process
  # so the user sees `mix hex.publish` output live instead of buffered.
  # Returns the exit status.
  #
  # Note: we intentionally do NOT force `MIX_ENV=prod` — `mix hex.publish`
  # needs `ex_doc` available to build documentation, and ex_doc is typically
  # declared as `only: :dev`. Letting the command inherit the caller's env
  # keeps both docs and prod deps available.
  defp run_streaming(cmd, args, cwd) do
    port =
      Port.open(
        {:spawn_executable, System.find_executable(cmd)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          {:args, args},
          {:cd, cwd},
          {:line, 4096}
        ]
      )

    stream_port(port)
  end

  defp stream_port(port) do
    receive do
      {^port, {:data, {_eol_flag, line}}} ->
        IO.puts(line)
        stream_port(port)

      {^port, {:data, data}} when is_binary(data) ->
        IO.write(data)
        stream_port(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end
end
