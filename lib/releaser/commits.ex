defmodule Releaser.Commits do
  @moduledoc """
  Reads Conventional Commits from `git log` and produces a per-app bump plan.

  ## Inputs

    * `since` — git ref to use as the lower bound (last release tag, etc.).
      When `nil`, auto-detected from the most recent `v*` tag, falling back
      to the full history.
    * `config` — the `:commits` section of `Releaser.Config.load/0`
      (`bump_rules`, `breaking_bump`, `breaking_markers`, `scope_aliases`,
      `no_scope`).
    * `apps` — list of `%Releaser.App{}` from `Releaser.Workspace.discover/1`.

  ## Output

  A list of `%{app: name, bump: :major | :minor | :patch, commits: [Commit.t()]}`
  for each app that receives a bump. Apps with no relevant commits are
  omitted entirely — callers should treat missing apps as "no bump".

  ## Breaking detection

  A commit is breaking if any of the configured `breaking_markers` applies:

    * `:bang` — `feat(xml)!: subject`
    * `:body` — `BREAKING CHANGE:` or `BREAKING-CHANGE:` in the body

  Breaking commits always use `breaking_bump` (default `:major`) regardless
  of type.

  ## Aggregation

  For each app, the highest bump among relevant commits wins:
  `major > minor > patch > none`. No summation — 10 `feat` commits still
  produce a single `:minor` bump.
  """

  @type bump :: :major | :minor | :patch | :none

  @type commit :: %{
          sha: String.t(),
          type: String.t(),
          scope: String.t() | nil,
          subject: String.t(),
          body: String.t(),
          breaking: boolean(),
          bump: bump()
        }

  @type plan_entry :: %{
          app: String.t(),
          bump: :major | :minor | :patch,
          commits: [commit()]
        }

  # Header: `type(scope)!: subject`
  @header_regex ~r/^(?<type>\w+)(?:\((?<scope>[^)]+)\))?(?<bang>!)?:\s*(?<subject>.+)$/

  # Body breaking marker — MUST be uppercase per spec v1.0.0.
  # Accepts `BREAKING CHANGE:` and `BREAKING-CHANGE:` (both spec-valid).
  @body_breaking_regex ~r/^BREAKING[ \-]CHANGE[ :]/m

  # Default separator used when piping `git log` with `--format`
  @log_separator "---COMMIT---"

  @doc """
  Returns a list of plan entries for apps that should bump.

  When no commits are relevant (or `--since` resolves to HEAD), returns `[]`.
  """
  @spec plan(keyword()) :: [plan_entry()]
  def plan(opts \\ []) do
    apps = Keyword.fetch!(opts, :apps)
    config = Keyword.fetch!(opts, :config)
    since = Keyword.get(opts, :since) || detect_last_tag()
    git_log_fun = Keyword.get(opts, :git_log, &read_git_log/1)

    raw = git_log_fun.(since)
    commits = parse_log(raw, config)

    no_scope_strategy = Map.get(config, :no_scope, :warn)
    handle_no_scope(commits, no_scope_strategy)

    commits
    |> group_by_app(apps, config)
    |> Enum.map(fn {app_name, app_commits} ->
      bump = aggregate_bump(app_commits)
      %{app: app_name, bump: bump, commits: app_commits}
    end)
    |> Enum.reject(&(&1.bump == :none))
    |> Enum.sort_by(& &1.app)
  end

  @doc """
  Parses the raw output of `git log` (with `@log_separator`) into a list of
  commit maps. Exposed for testing.
  """
  @spec parse_log(String.t(), map()) :: [commit()]
  def parse_log(raw, config) when is_binary(raw) do
    raw
    |> String.split(@log_separator, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_commit(&1, config))
    |> Enum.reject(&is_nil/1)
  end

  # -----------------------------------------------------------------------
  # Private
  # -----------------------------------------------------------------------

  defp parse_commit(raw, config) do
    # First line: "<sha> <header>", rest is body.
    case String.split(raw, "\n", parts: 2) do
      [first_line | rest] ->
        body = rest |> List.first() |> to_string() |> String.trim()

        case parse_first_line(first_line) do
          nil ->
            nil

          {sha, header} ->
            case Regex.named_captures(@header_regex, header) do
              nil ->
                nil

              %{"type" => type, "scope" => scope, "bang" => bang, "subject" => subject} ->
                breaking? = breaking?(bang, body, config)
                bump = bump_for(type, breaking?, config)
                scope_val = if scope == "", do: nil, else: scope

                %{
                  sha: sha,
                  type: type,
                  scope: scope_val,
                  subject: subject,
                  body: body,
                  breaking: breaking?,
                  bump: bump
                }
            end
        end

      _ ->
        nil
    end
  end

  defp parse_first_line(line) do
    case String.split(line, " ", parts: 2) do
      [sha, header] -> {sha, header}
      _ -> nil
    end
  end

  defp breaking?(bang, body, config) do
    markers = Map.get(config, :breaking_markers, [:bang, :body])

    cond do
      :bang in markers and bang == "!" -> true
      :body in markers and Regex.match?(@body_breaking_regex, body) -> true
      true -> false
    end
  end

  defp bump_for(_type, true = _breaking, config) do
    Map.get(config, :breaking_bump, :major)
  end

  defp bump_for(type, false, config) do
    config |> Map.get(:bump_rules, %{}) |> Map.get(type, :none)
  end

  defp group_by_app(commits, apps, config) do
    aliases = Map.get(config, :scope_aliases, %{})

    # Build reverse lookup: scope → app.name
    scope_to_app =
      Enum.reduce(aliases, %{}, fn {scope, app_name}, acc ->
        Map.put(acc, scope, app_name)
      end)

    no_scope = Map.get(config, :no_scope, :warn)

    Enum.reduce(commits, %{}, fn commit, acc ->
      case resolve_app(commit, apps, scope_to_app, no_scope) do
        nil ->
          acc

        app_name ->
          Map.update(acc, app_name, [commit], &[commit | &1])
      end
    end)
    |> Enum.map(fn {app, cs} -> {app, Enum.reverse(cs)} end)
    |> Enum.into(%{})
  end

  # Commits without a scope: route based on the `no_scope` strategy.
  defp resolve_app(%{scope: nil}, apps, _scope_to_app, {:apply_to, target}) do
    if Enum.any?(apps, &(&1.name == target)), do: target, else: nil
  end

  defp resolve_app(%{scope: nil}, _apps, _scope_to_app, _no_scope), do: nil

  defp resolve_app(%{scope: scope}, apps, scope_to_app, _no_scope) do
    # Split multi-scope commits like "feat(xml,csd): ..." — but we only return
    # the first match; callers who want multi-app behavior should extend.
    scope
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn s ->
      direct = Enum.find(apps, &(&1.name == s))
      aliased_name = Map.get(scope_to_app, s)
      aliased = aliased_name && Enum.find(apps, &(&1.name == aliased_name))
      stripped = Enum.find(apps, &(&1.name == strip_common_prefix(s) or strip_common_prefix(&1.name) == s))

      cond do
        direct -> direct.name
        aliased -> aliased.name
        stripped -> stripped.name
        true -> nil
      end
    end)
  end

  defp strip_common_prefix(name) when is_binary(name) do
    Regex.replace(~r/^(cfdi_|sat_|clir_|renapo_)/, name, "")
  end

  defp aggregate_bump(commits) do
    commits
    |> Enum.map(& &1.bump)
    |> Enum.reduce(:none, &max_bump/2)
  end

  # Semver hierarchy: major > minor > patch > none
  defp max_bump(a, b), do: higher(a, b)
  defp higher(:major, _), do: :major
  defp higher(_, :major), do: :major
  defp higher(:minor, _), do: :minor
  defp higher(_, :minor), do: :minor
  defp higher(:patch, _), do: :patch
  defp higher(_, :patch), do: :patch
  defp higher(_, _), do: :none

  defp handle_no_scope(_commits, :ignore), do: :ok
  defp handle_no_scope(_commits, {:apply_to, _}), do: :ok

  defp handle_no_scope(commits, :warn) do
    no_scope = Enum.filter(commits, &(&1.scope == nil and &1.bump != :none))

    if no_scope != [] do
      IO.warn(
        "#{length(no_scope)} commit(s) without scope were ignored. " <>
          "Consider adding a scope (e.g. `feat(xml): ...`)."
      )
    end

    :ok
  end

  defp handle_no_scope(_commits, _), do: :ok

  # -----------------------------------------------------------------------
  # Git interop
  # -----------------------------------------------------------------------

  @doc """
  Reads `git log <range> --format=...` and returns raw output.
  Exposed so tests can replace it with a fixture.
  """
  @spec read_git_log(String.t() | nil) :: String.t()
  def read_git_log(since) do
    range =
      case since do
        nil -> "HEAD"
        "" -> "HEAD"
        ref -> "#{ref}..HEAD"
      end

    format = "%H %s%n%b#{@log_separator}"
    args = ["log", range, "--format=#{format}", "--no-merges"]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {_, _} -> ""
    end
  end

  @doc """
  Returns the most recent tag matching `v*`, or `nil` when there is none.
  """
  @spec detect_last_tag() :: String.t() | nil
  def detect_last_tag do
    case System.cmd("git", ["describe", "--tags", "--abbrev=0", "--match=v*"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      {_, _} -> nil
    end
  end
end
