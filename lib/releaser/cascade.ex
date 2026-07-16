defmodule Releaser.Cascade do
  @moduledoc """
  Plans cascade version bumps through the dependency graph.

  When a package is bumped, all packages that depend on it receive a patch bump
  automatically (like Rush in Node.js).

  ## Cascading is idempotent

  A cascade does not mean "add a patch to whatever `mix.exs` says". It means
  "ensure this dependent has a bump pending for the current release cycle". The
  difference matters as soon as you bump twice before publishing:

      mix releaser.bump ex_pdf_components patch   # ex_pdf 1.0.6 -> 1.0.7
      mix releaser.bump ex_qr patch               # ex_pdf must stay at 1.0.7

  The second cascade reaches `ex_pdf` again, but its pending 1.0.7 already
  covers this cycle — bumping it to 1.0.8 would burn a version number that is
  never published. So each dependent is compared against its `Releaser.Baseline`
  (its last *released* version) and skipped when it is already ahead.

  Recursion still walks *through* skipped apps: a pending dependent may itself
  have clean dependents that do need a bump.

  The directly bumped app is never subject to this check — an explicit bump is
  user intent, not a cascade.
  """

  alias Releaser.{Baseline, Graph, Version}

  @doc """
  Plans version changes for an app and its publishable dependents.

  Returns the list of changes to write, each a map of
  `%{app:, path:, old:, new:, version_form:, reason:}` where `:reason` is
  `:direct` or `:cascade`.

  ## Options

    * `:cascade` — when `false`, only the direct app is bumped. Defaults to `true`.
    * `:baselines` — a `%{app_name => version | nil}` map, bypassing baseline
      resolution. Mainly for tests; production callers let it resolve.
  """
  def plan(app_name, new_version, apps, opts \\ []) do
    plan_all(app_name, new_version, apps, opts).changes
  end

  @doc """
  Like `plan/4`, but also reports dependents that were skipped.

  Returns `%{changes: [change], pending: [pending]}`, where `:pending` lists the
  dependents already ahead of their baseline as `%{app:, version:, baseline:}`.
  They need no write, but they ARE part of this release cycle — callers render
  them so a skipped app does not look like a forgotten one.
  """
  def plan_all(app_name, new_version, apps, opts \\ []) do
    cascade? = Keyword.get(opts, :cascade, true)
    publishable_apps = Enum.filter(apps, & &1.publish)
    dependents_map = Graph.dependents_of(publishable_apps)
    app = Enum.find(apps, &(&1.name == app_name))

    direct = %{
      app: app.name,
      path: app.path,
      old: app.version,
      new: new_version,
      version_form: app.version_form,
      reason: :direct
    }

    if cascade? do
      baselines =
        app_name
        |> cascade_targets(publishable_apps, dependents_map)
        |> baselines_for(opts)

      {changes, pending, _visited} =
        cascade(
          app_name,
          publishable_apps,
          dependents_map,
          baselines,
          {[direct], [], MapSet.new([app_name])}
        )

      %{changes: changes, pending: pending}
    else
      %{changes: [direct], pending: []}
    end
  end

  # Every publishable app transitively depending on app_name, excluding itself.
  defp cascade_targets(app_name, apps, dependents_map) do
    names =
      app_name
      |> collect_dependents(dependents_map, MapSet.new([app_name]))
      |> MapSet.delete(app_name)

    Enum.filter(apps, &MapSet.member?(names, &1.name))
  end

  defp collect_dependents(name, dependents_map, visited) do
    dependents_map
    |> Map.get(name, [])
    |> Enum.reduce(visited, fn dep, acc ->
      if MapSet.member?(acc, dep) do
        acc
      else
        collect_dependents(dep, dependents_map, MapSet.put(acc, dep))
      end
    end)
  end

  defp baselines_for(targets, opts) do
    case Keyword.get(opts, :baselines) do
      nil -> Baseline.resolve_many(targets, opts)
      provided -> provided
    end
  end

  # `visited` is threaded through the accumulator, not captured from the
  # enclosing scope: sibling branches of a diamond must see each other's visits,
  # otherwise a shared dependent is added once per path that reaches it.
  defp cascade(changed_app, apps, dependents_map, baselines, acc) do
    dependents_map
    |> Map.get(changed_app, [])
    |> Enum.reduce(acc, fn dep_name, {changes, pending, visited} = unchanged ->
      dep_app = Enum.find(apps, &(&1.name == dep_name))

      cond do
        MapSet.member?(visited, dep_name) ->
          unchanged

        is_nil(dep_app) ->
          unchanged

        true ->
          next =
            case baseline_for(dep_app, baselines) do
              {:pending, baseline} ->
                {changes, pending ++ [pending_entry(dep_app, baseline)],
                 MapSet.put(visited, dep_name)}

              :bump ->
                {changes ++ [cascade_change(dep_app)], pending, MapSet.put(visited, dep_name)}
            end

          cascade(dep_name, apps, dependents_map, baselines, next)
      end
    end)
  end

  # An app is pending when its working-tree version is already ahead of its
  # baseline — a previous bump in this cycle staged it and has not shipped yet.
  # No baseline (never published) means nothing to compare against: bump.
  defp baseline_for(app, baselines) do
    with baseline when is_binary(baseline) <- Map.get(baselines, app.name),
         {:ok, current} <- Elixir.Version.parse(app.version),
         {:ok, base} <- Elixir.Version.parse(baseline),
         :gt <- Elixir.Version.compare(current, base) do
      {:pending, baseline}
    else
      _ -> :bump
    end
  end

  defp cascade_change(app) do
    new_version =
      app.version
      |> Version.parse()
      |> Version.release()
      |> Version.bump(:patch)
      |> to_string()

    %{
      app: app.name,
      path: app.path,
      old: app.version,
      new: new_version,
      version_form: app.version_form,
      reason: :cascade
    }
  end

  defp pending_entry(app, baseline) do
    %{app: app.name, version: app.version, baseline: baseline}
  end
end
