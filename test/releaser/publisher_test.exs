defmodule Releaser.PublisherTest do
  use ExUnit.Case, async: false

  alias Releaser.{App, Publisher}

  @mix_template """
  defmodule <%= MODULE %>.MixProject do
    use Mix.Project

    def project do
      [
        app: :<%= APP %>,
        version: "<%= VERSION %>",
        releaser: [publish: true],
        deps: <%= DEPS %>
      ]
    end
  end
  """

  @mix_template_unpub """
  defmodule <%= MODULE %>.MixProject do
    use Mix.Project

    def project do
      [
        app: :<%= APP %>,
        version: "<%= VERSION %>",
        deps: <%= DEPS %>
      ]
    end
  end
  """

  # Helpers -----------------------------------------------------------

  defp make_tmp_root do
    path = Path.join(System.tmp_dir!(), "releaser_pub_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp write_app!(root, name, version, opts \\ []) do
    app_dir = Path.join([root, "apps", name])
    File.mkdir_p!(app_dir)

    deps = Keyword.get(opts, :deps, [])
    publish? = Keyword.get(opts, :publish, true)

    deps_str =
      "[" <>
        Enum.map_join(deps, ", ", fn d -> ~s({:#{d}, path: "../#{d}"}) end) <>
        "]"

    template = if publish?, do: @mix_template, else: @mix_template_unpub

    content =
      template
      |> String.replace("<%= MODULE %>", Macro.camelize(name))
      |> String.replace("<%= APP %>", name)
      |> String.replace("<%= VERSION %>", version)
      |> String.replace("<%= DEPS %>", deps_str)

    File.write!(Path.join(app_dir, "mix.exs"), content)
  end

  defp plan(root, statuses, extra_opts \\ []) do
    File.cd!(root, fn ->
      Publisher.plan([apps_root: "apps", statuses: statuses] ++ extra_opts)
    end)
  end

  # Tests -------------------------------------------------------------

  describe "plan/1 — Hex status filtering" do
    test "skips apps whose local version matches Hex" do
      root = make_tmp_root()
      write_app!(root, "libx", "1.0.0")

      statuses = %{
        "libx" => %{local: "1.0.0", hex: "1.0.0", status: :published}
      }

      result = plan(root, statuses)

      assert result.levels == []
      assert result.apps == []

      assert [%{app: "libx", local: "1.0.0", hex: "1.0.0", reason: :already_published}] =
               result.skipped
    end

    test "includes apps whose local version is ahead of Hex" do
      root = make_tmp_root()
      write_app!(root, "libx", "1.1.0")

      statuses = %{
        "libx" => %{local: "1.1.0", hex: "1.0.0", status: :ahead}
      }

      result = plan(root, statuses)

      assert result.skipped == []
      assert [app] = result.apps
      assert app.name == "libx"
    end

    test "includes apps not yet on Hex (unpublished)" do
      root = make_tmp_root()
      write_app!(root, "libx", "0.1.0")

      statuses = %{
        "libx" => %{local: "0.1.0", hex: nil, status: :unpublished}
      }

      result = plan(root, statuses)

      assert result.skipped == []
      assert [app] = result.apps
      assert app.name == "libx"
    end

    test "skips pre-release local versions" do
      root = make_tmp_root()
      write_app!(root, "libx", "1.1.0-dev.1")

      statuses = %{
        "libx" => %{local: "1.1.0-dev.1", hex: "1.0.0", status: :prerelease}
      }

      result = plan(root, statuses)

      assert [%{reason: :prerelease}] = result.skipped
      assert result.apps == []
    end

    test "mixed: publishes ahead + skips already-published" do
      root = make_tmp_root()
      write_app!(root, "fresh", "2.0.0")
      write_app!(root, "stale", "1.0.0")

      statuses = %{
        "fresh" => %{local: "2.0.0", hex: "1.5.0", status: :ahead},
        "stale" => %{local: "1.0.0", hex: "1.0.0", status: :published}
      }

      result = plan(root, statuses)

      assert [%{app: "stale"}] = result.skipped
      assert [app] = result.apps
      assert app.name == "fresh"
    end

    test "returns empty plan when every app is up to date" do
      root = make_tmp_root()
      write_app!(root, "a", "1.0.0")
      write_app!(root, "b", "2.0.0")

      statuses = %{
        "a" => %{local: "1.0.0", hex: "1.0.0", status: :published},
        "b" => %{local: "2.0.0", hex: "2.0.0", status: :published}
      }

      result = plan(root, statuses)

      assert result.levels == []
      assert result.apps == []
      assert length(result.skipped) == 2
    end
  end

  describe "plan/1 — blocking detection" do
    test "omits blocked apps from levels and apps; emits :blocked_by_deps in skipped" do
      root = make_tmp_root()
      write_app!(root, "openssl", "1.0.0", publish: false)
      write_app!(root, "csd", "2.0.0", deps: ["openssl"])

      statuses = %{"csd" => %{local: "2.0.0", hex: nil, status: :unpublished}}

      result = plan(root, statuses)

      refute Enum.any?(result.apps, &(&1.name == "csd"))
      refute Enum.any?(result.levels, fn {_lvl, names} -> "csd" in names end)

      assert [%{app: "csd", reason: :blocked_by_deps, blocked_by: ["openssl"]}] =
               result.skipped
    end

    test "blocked_by lists immediate dep, not transitive root" do
      root = make_tmp_root()
      write_app!(root, "b", "1.0.0", publish: false)
      write_app!(root, "c", "1.0.0", deps: ["b"])
      write_app!(root, "a", "1.0.0", deps: ["c"])

      statuses = %{
        "a" => %{local: "1.0.0", hex: nil, status: :unpublished},
        "c" => %{local: "1.0.0", hex: nil, status: :unpublished}
      }

      result = plan(root, statuses)

      a_entry = Enum.find(result.skipped, &(&1.app == "a"))
      c_entry = Enum.find(result.skipped, &(&1.app == "c"))

      assert a_entry.reason == :blocked_by_deps
      assert a_entry.blocked_by == ["c"]
      assert c_entry.reason == :blocked_by_deps
      assert c_entry.blocked_by == ["b"]
    end

    test "blocking applies before Hex status check (no :already_published for blocked app)" do
      root = make_tmp_root()
      write_app!(root, "openssl", "1.0.0", publish: false)
      write_app!(root, "csd", "2.0.0", deps: ["openssl"])

      # csd would otherwise be :already_published; blocking must override.
      statuses = %{"csd" => %{local: "2.0.0", hex: "2.0.0", status: :published}}

      result = plan(root, statuses)

      csd_entry = Enum.find(result.skipped, &(&1.app == "csd"))
      assert csd_entry.reason == :blocked_by_deps
      refute csd_entry.reason == :already_published
    end

    test "emits no :blocked_by_deps when no blocking exists" do
      root = make_tmp_root()
      write_app!(root, "a", "1.0.0")
      write_app!(root, "b", "1.0.0", deps: ["a"])

      statuses = %{
        "a" => %{local: "1.0.0", hex: nil, status: :unpublished},
        "b" => %{local: "1.0.0", hex: nil, status: :unpublished}
      }

      result = plan(root, statuses)

      refute Enum.any?(result.skipped, &(&1.reason == :blocked_by_deps))
    end

    test "non-publishable apps are not part of skipped entries" do
      root = make_tmp_root()
      write_app!(root, "openssl", "1.0.0", publish: false)
      write_app!(root, "csd", "2.0.0", deps: ["openssl"])

      statuses = %{"csd" => %{local: "2.0.0", hex: nil, status: :unpublished}}

      result = plan(root, statuses)

      refute Enum.any?(result.skipped, &(&1.app == "openssl"))
    end
  end

  describe "blocked_names/1" do
    test "returns app with direct non-publishable dep" do
      apps = [
        %App{name: "csd", path: "apps/csd", version: "2.0.0", deps: ["openssl"], publish: true},
        %App{name: "openssl", path: "apps/openssl", version: "1.0.0", deps: [], publish: false}
      ]

      assert Publisher.blocked_names(apps) == MapSet.new(["csd"])
    end

    test "returns A and C when B is non-publishable (A→C→B transitive)" do
      apps = [
        %App{name: "a", path: "apps/a", version: "1.0.0", deps: ["c"], publish: true},
        %App{name: "c", path: "apps/c", version: "1.0.0", deps: ["b"], publish: true},
        %App{name: "b", path: "apps/b", version: "1.0.0", deps: [], publish: false}
      ]

      assert Publisher.blocked_names(apps) == MapSet.new(["a", "c"])
    end

    test "returns empty MapSet when all deps publishable" do
      apps = [
        %App{name: "a", path: "apps/a", version: "1.0.0", deps: ["b"], publish: true},
        %App{name: "b", path: "apps/b", version: "1.0.0", deps: [], publish: true}
      ]

      assert Publisher.blocked_names(apps) == MapSet.new()
    end

    test "returns empty MapSet for standalone publishable app with no deps" do
      apps = [%App{name: "safe", path: "apps/safe", version: "1.0.0", deps: [], publish: true}]

      assert Publisher.blocked_names(apps) == MapSet.new()
    end

    @tag timeout: 5_000
    test "handles cycle among publishable apps and terminates" do
      # a → b → a (cycle), a → c (non-publishable)
      apps = [
        %App{name: "a", path: "apps/a", version: "1.0.0", deps: ["b", "c"], publish: true},
        %App{name: "b", path: "apps/b", version: "1.0.0", deps: ["a"], publish: true},
        %App{name: "c", path: "apps/c", version: "1.0.0", deps: [], publish: false}
      ]

      assert Publisher.blocked_names(apps) == MapSet.new(["a", "b"])
    end

    test "non-publishable apps are causes, never members of the blocked set" do
      apps = [
        %App{name: "a", path: "apps/a", version: "1.0.0", deps: ["b"], publish: true},
        %App{name: "b", path: "apps/b", version: "1.0.0", deps: [], publish: false}
      ]

      result = Publisher.blocked_names(apps)
      assert MapSet.member?(result, "a")
      refute MapSet.member?(result, "b")
    end
  end

  describe "blocked_with_reasons/1" do
    test "returns map with immediate causes only — not transitive root" do
      apps = [
        %App{name: "a", path: "apps/a", version: "1.0.0", deps: ["c"], publish: true},
        %App{name: "c", path: "apps/c", version: "1.0.0", deps: ["b"], publish: true},
        %App{name: "b", path: "apps/b", version: "1.0.0", deps: [], publish: false}
      ]

      result = Publisher.blocked_with_reasons(apps)
      assert result == %{"c" => ["b"], "a" => ["c"]}
    end

    test "lists multiple immediate blocking deps" do
      apps = [
        %App{name: "a", path: "apps/a", version: "1.0.0", deps: ["x", "y"], publish: true},
        %App{name: "x", path: "apps/x", version: "1.0.0", deps: [], publish: false},
        %App{name: "y", path: "apps/y", version: "1.0.0", deps: [], publish: false}
      ]

      assert %{"a" => deps} = Publisher.blocked_with_reasons(apps)
      assert Enum.sort(deps) == ["x", "y"]
    end
  end
end
