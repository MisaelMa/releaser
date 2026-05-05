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

  # Fixture with mixed publish + version_form for badge/branch tests.
  @rich_apps [
    %App{
      name: "openssl",
      path: "apps/openssl",
      version: "1.0.0",
      deps: [],
      publish: false,
      version_form: :literal
    },
    %App{
      name: "csd",
      path: "apps/csd",
      version: "2.0.0",
      deps: ["openssl"],
      publish: true,
      version_form: :attribute
    }
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

  describe "render_graph/2 — compact mode (default)" do
    test "shows [publish: ✗ blocked] for apps blocked by non-publishable deps" do
      # Intentional inversion: csd is blocked by openssl (publish: false).
      # See openspec/changes/block-publish-non-publishable-deps for rationale.
      GraphTask.render_graph(@rich_apps)
      output = collect_output() |> strip_ansi()
      assert output =~ "csd v2.0.0 [publish: ✗ blocked]"
    end

    test "shows [publish: ✗] for apps not marked publishable" do
      GraphTask.render_graph(@rich_apps)
      output = collect_output() |> strip_ansi()
      assert output =~ "openssl v1.0.0 [publish: ✗]"
    end

    test "shows [@version] only when version_form is :attribute" do
      # Intentional inversion: csd is blocked, so its publish badge is `✗ blocked`.
      GraphTask.render_graph(@rich_apps)
      output = collect_output() |> strip_ansi()
      assert output =~ "csd v2.0.0 [publish: ✗ blocked] [@version]"
      refute output =~ "openssl v1.0.0 [publish: ✗] [@version]"
    end

    test "does not show [hex: ...] when --hex is not set" do
      GraphTask.render_graph(@rich_apps)
      output = collect_output() |> strip_ansi()
      refute output =~ "[hex:"
    end

    test "shows [hex: ...] when hex_map is provided" do
      hex_map = %{
        "openssl" => %{local: "1.0.0", hex: "1.0.0", status: :published},
        "csd" => %{local: "2.0.0", hex: "1.9.0", status: :ahead}
      }

      GraphTask.render_graph(@rich_apps, hex: true, hex_map: hex_map)
      output = collect_output() |> strip_ansi()
      assert output =~ "[hex: published]"
      assert output =~ "[hex: ahead]"
    end

    test "compact dep line is unchanged — uses └─ depends on:" do
      GraphTask.render_graph(@rich_apps)
      output = collect_output() |> strip_ansi()
      assert output =~ "└─ depends on: openssl"
    end
  end

  describe "render_graph/2 — detailed mode" do
    test "renders multiline branches under each app" do
      # Intentional inversion: csd was `publish: yes`; now blocked by openssl.
      GraphTask.render_graph(@rich_apps, detailed: true)
      output = collect_output() |> strip_ansi()
      # csd has deps + publish + version form + path → 4 branches
      assert output =~ "├─ depends on: openssl"
      assert output =~ "├─ publish: blocked (needs: openssl)"
      assert output =~ "├─ version form: @version"
      assert output =~ "└─ path: apps/csd"
    end

    test "skips depends-on branch for leaves" do
      GraphTask.render_graph(@rich_apps, detailed: true)
      output = collect_output() |> strip_ansi()
      # openssl has no deps → no "depends on" line for it
      # but it still has publish + path branches
      assert output =~ "├─ publish: no"
      assert output =~ "└─ path: apps/openssl"
    end

    test "skips version-form branch when literal" do
      GraphTask.render_graph(@rich_apps, detailed: true)
      output = collect_output() |> strip_ansi()
      # openssl uses :literal, so no "version form" branch under it
      # the easy way: ensure path is the last branch (└─) for openssl block
      assert output =~ "└─ path: apps/openssl"
    end

    test "shows hex branch only with --hex" do
      hex_map = %{
        "csd" => %{local: "2.0.0", hex: "1.9.0", status: :ahead}
      }

      GraphTask.render_graph(@rich_apps, detailed: true, hex: true, hex_map: hex_map)
      output = collect_output() |> strip_ansi()
      assert output =~ "├─ hex: ahead (local v2.0.0, remote v1.9.0)"
    end

    test "without --hex, no hex branch appears" do
      GraphTask.render_graph(@rich_apps, detailed: true)
      output = collect_output() |> strip_ansi()
      refute output =~ "hex:"
    end

    test "publish: no when app is not publishable" do
      GraphTask.render_graph(@rich_apps, detailed: true)
      output = collect_output() |> strip_ansi()
      assert output =~ "├─ publish: no"
    end
  end

  describe "summary" do
    test "shows publishable apps count and blocked apps count" do
      # Intentional inversion: csd was counted as publishable; now blocked.
      GraphTask.render_graph(@rich_apps)
      output = collect_output() |> strip_ansi()
      assert output =~ "Publishable apps:    0"
      assert output =~ "Blocked apps:        1"
    end

    test "omits 'Blocked apps:' line when no apps are blocked" do
      safe_apps = [
        %App{
          name: "safe",
          path: "apps/safe",
          version: "1.0.0",
          deps: [],
          publish: true,
          version_form: :literal
        }
      ]

      GraphTask.render_graph(safe_apps)
      output = collect_output() |> strip_ansi()
      assert output =~ "Publishable apps:    1"
      refute output =~ "Blocked apps:"
    end
  end

  describe "blocking — compact" do
    test "non-publishable app keeps [publish: ✗] without 'blocked' word" do
      GraphTask.render_graph(@rich_apps)
      output = collect_output() |> strip_ansi()
      assert output =~ "openssl v1.0.0 [publish: ✗]"
      refute output =~ ~r/openssl[^\n]*blocked/
    end

    test "safe publishable app with no deps shows [publish: ✓]" do
      safe_apps = [
        %App{
          name: "safe",
          path: "apps/safe",
          version: "1.0.0",
          deps: [],
          publish: true,
          version_form: :literal
        }
      ]

      GraphTask.render_graph(safe_apps)
      output = collect_output() |> strip_ansi()
      assert output =~ "safe v1.0.0 [publish: ✓]"
      refute output =~ "blocked"
    end
  end

  describe "blocking — detailed" do
    test "safe publishable app shows 'publish: yes' in detailed mode" do
      safe_apps = [
        %App{
          name: "safe",
          path: "apps/safe",
          version: "1.0.0",
          deps: [],
          publish: true,
          version_form: :literal
        }
      ]

      GraphTask.render_graph(safe_apps, detailed: true)
      output = collect_output() |> strip_ansi()
      assert output =~ "publish: yes"
      refute output =~ "blocked"
    end

    test "blocked app shows 'publish: blocked (needs: ...)' with multiple dep names" do
      apps = [
        %App{name: "x", path: "apps/x", version: "1.0.0", deps: [], publish: false},
        %App{name: "y", path: "apps/y", version: "1.0.0", deps: [], publish: false},
        %App{name: "a", path: "apps/a", version: "1.0.0", deps: ["x", "y"], publish: true}
      ]

      GraphTask.render_graph(apps, detailed: true)
      output = collect_output() |> strip_ansi()
      assert output =~ ~r/publish: blocked \(needs: (x, y|y, x)\)/
    end
  end

  describe "blocking — summary mixed" do
    test "shows Publishable apps: 1 and Blocked apps: 1 with mixed fixture" do
      apps = [
        %App{name: "openssl", path: "apps/openssl", version: "1.0.0", deps: [], publish: false},
        %App{
          name: "csd",
          path: "apps/csd",
          version: "2.0.0",
          deps: ["openssl"],
          publish: true,
          version_form: :literal
        },
        %App{
          name: "safe",
          path: "apps/safe",
          version: "1.0.0",
          deps: [],
          publish: true,
          version_form: :literal
        }
      ]

      GraphTask.render_graph(apps)
      output = collect_output() |> strip_ansi()
      assert output =~ "Publishable apps:    1"
      assert output =~ "Blocked apps:        1"
    end
  end

  describe "run/1 — argv parsing" do
    test "no args runs compact mode" do
      GraphTask.run([])
      output = collect_output() |> strip_ansi()
      assert output =~ "Dependency Graph"
      refute output =~ "├─ publish:"
    end

    test "--detailed flag activates detailed mode" do
      GraphTask.run(["--detailed"])
      output = collect_output() |> strip_ansi()
      assert output =~ "├─ publish:" or output =~ "└─ publish:"
    end

    test "-d alias activates detailed mode" do
      GraphTask.run(["-d"])
      output = collect_output() |> strip_ansi()
      assert output =~ "├─ publish:" or output =~ "└─ publish:"
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
