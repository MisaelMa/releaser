defmodule Mix.Tasks.Releaser.CheckCommitMsg do
  @shortdoc "Validate a commit message against Conventional Commits rules"
  @moduledoc """
  Reads a commit message file and validates it against the project's
  Conventional Commits configuration.

  Designed to be invoked from a git `commit-msg` hook:

      # .githooks/commit-msg
      #!/usr/bin/env sh
      exec mix releaser.check_commit_msg "$1"

  ## Exit codes

    * `0` — valid commit message
    * `1` — invalid; a human-readable error is printed to stderr

  ## Configuration

  Reads `:commits` from `mix.exs`. The feature is only active when
  `commits: [enabled: true]` is configured. When disabled, this task
  exits `0` silently (so the hook is a no-op in projects that haven't
  opted in).
  """

  use Mix.Task

  alias Releaser.{CommitValidator, UI, Workspace}

  @impl Mix.Task
  def run([path]) do
    config = Releaser.Config.load()
    commits_config = Map.get(config, :commits, %{})

    unless Map.get(commits_config, :enabled, false) do
      # Feature not enabled — hook is a no-op.
      System.halt(0)
    end

    raw =
      case File.read(path) do
        {:ok, content} -> content
        {:error, _} -> ""
      end

    apps = Workspace.discover()

    case CommitValidator.validate(raw, commits_config, apps: apps) do
      :ok ->
        System.halt(0)

      {:error, reason} ->
        print_error(reason, raw, commits_config, apps)
        System.halt(1)
    end
  end

  def run(_) do
    UI.error("Usage: mix releaser.check_commit_msg PATH_TO_COMMIT_MSG")
    System.halt(2)
  end

  defp print_error(reason, raw, commits_config, apps) do
    header = raw |> String.split("\n") |> Enum.at(0, "")

    IO.puts(:stderr, """
    #{UI.red("✗ Commit message invalid")}

        #{UI.bright(header)}

    #{CommitValidator.format_error(reason, commits_config, apps)}
    #{examples(commits_config, apps)}
    """)
  end

  defp examples(commits_config, apps) do
    scopes = CommitValidator.resolve_allowed_scopes(commits_config, apps)
    sample_scope = List.first(scopes) || "app"

    """
    Examples of valid commits:
      feat(#{sample_scope}): add new feature
      fix(#{sample_scope}): correct a bug
      feat(#{sample_scope})!: breaking change
      chore: global maintenance

    See guides/conventional-commits.md for details.
    """
  end
end
