defmodule Mix.Tasks.Releaser.InstallHooks do
  @shortdoc "Enable the project's git hooks (core.hooksPath)"
  @moduledoc """
  Configures git to use the repository's `.githooks/` directory instead of
  the local, per-clone `.git/hooks/`. After running once, hooks such as
  `commit-msg` (which validates Conventional Commits) apply automatically
  on every commit.

  ## Usage

      mix releaser.install_hooks

  ## What it does

  Runs `git config core.hooksPath .githooks`.

  ## Uninstalling

      git config --unset core.hooksPath
  """

  use Mix.Task

  alias Releaser.UI

  @hooks_dir ".githooks"

  @impl Mix.Task
  def run(_args) do
    unless File.dir?(@hooks_dir) do
      Mix.raise(
        "Directory `#{@hooks_dir}` does not exist. " <>
          "Run this task from the project root."
      )
    end

    # Make sure every script in .githooks is executable.
    @hooks_dir
    |> File.ls!()
    |> Enum.each(fn name ->
      path = Path.join(@hooks_dir, name)
      if File.regular?(path), do: File.chmod!(path, 0o755)
    end)

    case System.cmd("git", ["config", "core.hooksPath", @hooks_dir], stderr_to_stdout: true) do
      {_, 0} ->
        UI.info(UI.green("✓ git core.hooksPath set to #{@hooks_dir}"))
        UI.info("Hooks active:")

        @hooks_dir
        |> File.ls!()
        |> Enum.sort()
        |> Enum.each(fn name ->
          UI.info("  • #{name}")
        end)

      {out, _code} ->
        Mix.raise("git config failed:\n#{out}")
    end
  end
end
