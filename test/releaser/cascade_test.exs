defmodule Releaser.CascadeTest do
  use ExUnit.Case, async: true

  alias Releaser.{Cascade, App}

  # The user-reported scenario (elixir-pdf):
  #
  #   ex_qr <- ex_pdf_components <- ex_pdf
  #
  # `mix releaser.bump ex_pdf_components patch` bumps components and cascades
  # to ex_pdf. Running `mix releaser.bump ex_qr patch` right after must NOT
  # bump components/ex_pdf a second time — their first bump is still pending
  # (uncommitted, unpublished), so it already covers this release cycle.
  @pdf_apps [
    %App{name: "ex_qr", path: "apps/ex_qr", version: "0.1.0", deps: [], publish: true},
    %App{
      name: "ex_pdf_components",
      path: "apps/ex_pdf_components",
      version: "1.0.2",
      deps: ["ex_qr"],
      publish: true
    },
    %App{
      name: "ex_pdf",
      path: "apps/ex_pdf",
      version: "1.0.6",
      deps: ["ex_pdf_components"],
      publish: true
    }
  ]

  # Same graph, but after `bump ex_pdf_components patch` already ran:
  # working-tree versions are ahead of what is published.
  @pdf_apps_dirty [
    %App{name: "ex_qr", path: "apps/ex_qr", version: "0.1.0", deps: [], publish: true},
    %App{
      name: "ex_pdf_components",
      path: "apps/ex_pdf_components",
      version: "1.0.3",
      deps: ["ex_qr"],
      publish: true
    },
    %App{
      name: "ex_pdf",
      path: "apps/ex_pdf",
      version: "1.0.7",
      deps: ["ex_pdf_components"],
      publish: true
    }
  ]

  # Baselines = last published versions.
  @pdf_published %{"ex_qr" => "0.1.0", "ex_pdf_components" => "1.0.2", "ex_pdf" => "1.0.6"}

  defp change_for(changes, app), do: Enum.find(changes, &(&1.app == app))
  defp changed_apps(changes), do: Enum.map(changes, & &1.app)

  describe "plan/4 — direct change" do
    test "always includes the directly bumped app" do
      changes =
        Cascade.plan("ex_qr", "0.1.1", @pdf_apps, cascade: false, baselines: @pdf_published)

      assert [%{app: "ex_qr", old: "0.1.0", new: "0.1.1", reason: :direct}] = changes
    end

    test "bumps the direct app even when it is already ahead of its baseline" do
      # An explicit `mix releaser.bump ex_qr patch` is user intent, not a
      # cascade. It is never suppressed by the pending check.
      apps = [%App{name: "ex_qr", path: "apps/ex_qr", version: "0.1.1", deps: [], publish: true}]

      changes = Cascade.plan("ex_qr", "0.1.2", apps, baselines: %{"ex_qr" => "0.1.0"})

      assert [%{app: "ex_qr", old: "0.1.1", new: "0.1.2", reason: :direct}] = changes
    end

    test "--no-cascade skips dependents entirely" do
      changes =
        Cascade.plan("ex_qr", "0.1.1", @pdf_apps, cascade: false, baselines: @pdf_published)

      assert changed_apps(changes) == ["ex_qr"]
    end
  end

  describe "plan/4 — cascade on a clean working tree" do
    test "patch-bumps every transitive publishable dependent" do
      changes = Cascade.plan("ex_qr", "0.1.1", @pdf_apps, baselines: @pdf_published)

      assert %{old: "0.1.0", new: "0.1.1", reason: :direct} = change_for(changes, "ex_qr")

      assert %{old: "1.0.2", new: "1.0.3", reason: :cascade} =
               change_for(changes, "ex_pdf_components")

      assert %{old: "1.0.6", new: "1.0.7", reason: :cascade} = change_for(changes, "ex_pdf")
    end

    test "does not cascade to non-publishable apps" do
      apps = [
        %App{name: "core", path: "apps/core", version: "1.0.0", deps: [], publish: true},
        %App{name: "internal", path: "apps/internal", version: "2.0.0", deps: ["core"], publish: false}
      ]

      changes = Cascade.plan("core", "1.0.1", apps, baselines: %{"core" => "1.0.0"})

      assert changed_apps(changes) == ["core"]
    end
  end

  describe "plan/4 — pending bumps are not re-bumped (regression)" do
    test "reproduces the reported bug: ex_pdf must not jump 1.0.6 -> 1.0.8" do
      # `bump ex_pdf_components patch` already staged components 1.0.3 and
      # ex_pdf 1.0.7. Bumping ex_qr now must leave both untouched.
      changes = Cascade.plan("ex_qr", "0.1.1", @pdf_apps_dirty, baselines: @pdf_published)

      assert changed_apps(changes) == ["ex_qr"]
      refute change_for(changes, "ex_pdf")
      refute change_for(changes, "ex_pdf_components")
    end

    test "a dependent whose working version is ahead of its baseline is skipped" do
      changes = Cascade.plan("ex_qr", "0.1.1", @pdf_apps_dirty, baselines: @pdf_published)

      refute change_for(changes, "ex_pdf_components")
    end

    test "cascade recursion continues THROUGH a pending dependent" do
      # components is pending (1.0.3 > 1.0.2) but ex_pdf is NOT (1.0.6 == 1.0.6).
      # Skipping components must not orphan ex_pdf — it still needs its bump.
      apps = [
        %App{name: "ex_qr", path: "apps/ex_qr", version: "0.1.0", deps: [], publish: true},
        %App{
          name: "ex_pdf_components",
          path: "apps/ex_pdf_components",
          version: "1.0.3",
          deps: ["ex_qr"],
          publish: true
        },
        %App{
          name: "ex_pdf",
          path: "apps/ex_pdf",
          version: "1.0.6",
          deps: ["ex_pdf_components"],
          publish: true
        }
      ]

      changes = Cascade.plan("ex_qr", "0.1.1", apps, baselines: @pdf_published)

      refute change_for(changes, "ex_pdf_components")
      assert %{old: "1.0.6", new: "1.0.7", reason: :cascade} = change_for(changes, "ex_pdf")
    end

    test "cascade is idempotent: applying the plan and replanning yields no new bumps" do
      first = Cascade.plan("ex_qr", "0.1.1", @pdf_apps, baselines: @pdf_published)

      # Simulate FileSync writing the plan to mix.exs.
      applied =
        Enum.map(@pdf_apps, fn app ->
          case change_for(first, app.name) do
            nil -> app
            %{new: new} -> %{app | version: new}
          end
        end)

      second = Cascade.plan("ex_qr", "0.1.2", applied, baselines: @pdf_published)

      # ex_qr is direct so it bumps again, but nothing cascades a second time.
      assert changed_apps(second) == ["ex_qr"]
    end
  end

  describe "plan/4 — missing baselines" do
    test "cascades normally when an app has no baseline (never published)" do
      # A brand-new app has no Hex release, no tag, no HEAD version. With no
      # baseline there is nothing to compare against, so we bump — the old
      # behavior is the safe fallback.
      changes = Cascade.plan("ex_qr", "0.1.1", @pdf_apps, baselines: %{})

      assert %{old: "1.0.2", new: "1.0.3"} = change_for(changes, "ex_pdf_components")
      assert %{old: "1.0.6", new: "1.0.7"} = change_for(changes, "ex_pdf")
    end

    test "treats a nil baseline the same as a missing one" do
      baselines = %{"ex_pdf_components" => nil, "ex_pdf" => nil}
      changes = Cascade.plan("ex_qr", "0.1.1", @pdf_apps, baselines: baselines)

      assert %{new: "1.0.3"} = change_for(changes, "ex_pdf_components")
      assert %{new: "1.0.7"} = change_for(changes, "ex_pdf")
    end

    test "cascades when the working version is BEHIND its baseline" do
      # Someone published 1.0.9 out-of-band while mix.exs still says 1.0.6.
      # Not pending — the local version is stale, not staged. Bump it.
      baselines = %{"ex_pdf_components" => "1.0.2", "ex_pdf" => "1.0.9"}
      changes = Cascade.plan("ex_qr", "0.1.1", @pdf_apps, baselines: baselines)

      assert %{old: "1.0.6", new: "1.0.7", reason: :cascade} = change_for(changes, "ex_pdf")
    end
  end

  describe "plan/4 — diamond dependency" do
    @diamond [
      %App{name: "base", path: "apps/base", version: "1.0.0", deps: [], publish: true},
      %App{name: "left", path: "apps/left", version: "1.0.0", deps: ["base"], publish: true},
      %App{name: "right", path: "apps/right", version: "1.0.0", deps: ["base"], publish: true},
      %App{name: "top", path: "apps/top", version: "1.0.0", deps: ["left", "right"], publish: true}
    ]

    test "bumps a shared dependent exactly once" do
      baselines = Map.new(@diamond, &{&1.name, "1.0.0"})
      changes = Cascade.plan("base", "1.0.1", @diamond, baselines: baselines)

      assert Enum.count(changes, &(&1.app == "top")) == 1
      assert %{old: "1.0.0", new: "1.0.1"} = change_for(changes, "top")
    end

    test "skips a pending arm without skipping the clean one" do
      apps = [
        %App{name: "base", path: "apps/base", version: "1.0.0", deps: [], publish: true},
        %App{name: "left", path: "apps/left", version: "1.0.5", deps: ["base"], publish: true},
        %App{name: "right", path: "apps/right", version: "1.0.0", deps: ["base"], publish: true}
      ]

      baselines = %{"base" => "1.0.0", "left" => "1.0.4", "right" => "1.0.0"}
      changes = Cascade.plan("base", "1.0.1", apps, baselines: baselines)

      refute change_for(changes, "left")
      assert %{new: "1.0.1"} = change_for(changes, "right")
    end
  end

  describe "plan/4 — pre-release versions" do
    test "a pre-release ahead of its baseline counts as pending" do
      apps = [
        %App{name: "ex_qr", path: "apps/ex_qr", version: "0.1.0", deps: [], publish: true},
        %App{
          name: "ex_pdf_components",
          path: "apps/ex_pdf_components",
          version: "1.0.3-dev.1",
          deps: ["ex_qr"],
          publish: true
        }
      ]

      baselines = %{"ex_qr" => "0.1.0", "ex_pdf_components" => "1.0.2"}
      changes = Cascade.plan("ex_qr", "0.1.1", apps, baselines: baselines)

      refute change_for(changes, "ex_pdf_components")
    end
  end
end
