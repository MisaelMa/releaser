defmodule Mix.Tasks.Releaser.GraphTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Releaser.Graph, as: GraphTask
  alias Releaser.App

  # ── Fixture apps: a 3-node chain ──────────────────────────────────────────
  # openssl  (level 0, leaf: dep_count=0, deep_count=0)
  # csd      (level 1, dep_count=1, deep_count=0)  → depends on openssl
  # xml      (level 2, dep_count=1, deep_count=1)  → depends on csd
  @fixture_apps [
    %App{name: "openssl", path: "apps/openssl", version: "1.0.0", deps: []},
    %App{name: "csd", path: "apps/csd", version: "2.0.0", deps: ["openssl"]},
    %App{name: "xml", path: "apps/xml", version: "3.0.0", deps: ["csd"]}
  ]

  setup do
    original_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(original_shell) end)
    :ok
  end

  defp collect_output do
    receive do
      {:mix_shell, :info, [line]} -> line <> "\n" <> collect_output()
    after
      0 -> ""
    end
  end

  defp strip_ansi(text), do: Regex.replace(~r/\e\[[0-9;]*m/, text, "")

  describe "render_graph/1 — levels view" do
    test "leaf dep is rendered as bare name with no brackets" do
      GraphTask.render_graph(@fixture_apps)
      output = collect_output() |> strip_ansi()
      # openssl is at level 0 with no deps — must appear bare, no brackets
      assert output =~ "openssl"
      refute output =~ "openssl["
    end

    test "non-leaf dep annotated with [level][count][deep]" do
      GraphTask.render_graph(@fixture_apps)
      output = collect_output() |> strip_ansi()
      # csd is at level 1, dep_count=1, deep_count=0
      # xml lists csd as its dep → csd must appear annotated as csd[1][1][0]
      assert output =~ "csd[1][1][0]"
    end

    test "deeper non-leaf annotated correctly" do
      GraphTask.render_graph(@fixture_apps)
      output = collect_output() |> strip_ansi()
      # xml is at level 2, dep_count=1, deep_count=1 (csd has deps)
      # but xml itself appears as an app header, not as a dep annotation
      # csd is listed as dep of xml: csd[1][1][0]
      assert output =~ ~r/\[\d+\]\[\d+\]\[\d+\]/
    end
  end

  describe "run/1 — no-arg form (live workspace)" do
    test "self-hosted workspace: releaser has no brackets (leaf)" do
      GraphTask.run([])
      output = collect_output() |> strip_ansi()
      # The releaser project itself has no path deps, so it must be a leaf
      # Its name appears in the header as a green app name, not as an annotated dep
      # But since there are no internal deps listed under it, no bracket annotations appear
      refute output =~ ~r/releaser\[/
    end
  end

  describe "run/1 — single-arg form (dependents tree)" do
    test "no bracket annotations in output" do
      # run with any app name — the dependents tree never annotates
      apps = Releaser.Workspace.discover()
      app_name = List.first(apps).name
      GraphTask.run([app_name])
      output = collect_output() |> strip_ansi()
      refute output =~ ~r/\[\d+\]\[\d+\]\[\d+\]/
    end
  end
end
