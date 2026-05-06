defmodule Releaser.GraphTest do
  use ExUnit.Case, async: true

  alias Releaser.{Graph, App}

  @apps [
    %App{name: "openssl", path: "apps/clir/openssl", version: "0.0.17", deps: []},
    %App{name: "transform", path: "apps/cfdi/transform", version: "4.0.14", deps: []},
    %App{name: "catalogos", path: "apps/cfdi/catalogos", version: "4.0.16", deps: []},
    %App{name: "csd", path: "apps/cfdi/csd", version: "4.0.16", deps: ["openssl"]},
    %App{name: "xml", path: "apps/cfdi/xml", version: "4.0.18", deps: ["csd", "transform", "catalogos"]},
    %App{name: "auth", path: "apps/sat/auth", version: "1.0.1", deps: ["csd"]},
    %App{name: "cancelacion", path: "apps/cfdi/cancelacion", version: "0.0.1", deps: ["auth"]}
  ]

  describe "build/1" do
    test "builds graph from apps" do
      graph = Graph.build(@apps)
      assert graph["openssl"] == []
      assert graph["csd"] == ["openssl"]
      assert "csd" in graph["xml"]
      assert "transform" in graph["xml"]
    end
  end

  describe "dependents_of/1" do
    test "returns reverse dependency map" do
      dep_map = Graph.dependents_of(@apps)
      assert "csd" in dep_map["openssl"]
      assert "xml" in dep_map["csd"]
      assert "auth" in dep_map["csd"]
      assert "cancelacion" in dep_map["auth"]
    end
  end

  describe "topological_levels/1" do
    test "produces correct levels" do
      levels = Graph.topological_levels(@apps)

      assert [{0, level0}, {1, level1}, {2, level2}, {3, level3}] = levels

      assert "openssl" in level0
      assert "transform" in level0
      assert "catalogos" in level0

      assert level1 == ["csd"]

      assert "xml" in level2
      assert "auth" in level2

      assert level3 == ["cancelacion"]
    end

    test "level 0 has no internal deps" do
      [{0, level0} | _] = Graph.topological_levels(@apps)
      graph = Graph.build(@apps)

      Enum.each(level0, fn name ->
        assert Map.get(graph, name, []) == []
      end)
    end

    test "treats deps outside the input set as already satisfied" do
      # Reproduces the publish-subset bug: when callers filter to a subset of
      # apps (e.g. `Publisher.plan/1` skipping already-on-Hex apps), the
      # remaining apps still reference deps that are NOT in the subset. Those
      # external deps must be treated as satisfied — they are NOT a missing
      # ordering constraint and must NOT trigger a false circular_dependency.
      apps = [
        %App{
          name: "cfdi",
          path: "p/cfdi",
          version: "1.0.0",
          deps: ["sat_certificados", "cfdi_xml", "sat_catalogos"]
        },
        %App{
          name: "sat_certificados",
          path: "p/sat",
          version: "1.0.0",
          deps: ["clir_openssl"]
        }
      ]

      assert [{0, ["sat_certificados"]}, {1, ["cfdi"]}] = Graph.topological_levels(apps)
    end

    test "single app with only external deps lands at level 0" do
      apps = [
        %App{name: "a", path: "p/a", version: "1.0.0", deps: ["external_only"]}
      ]

      assert [{0, ["a"]}] = Graph.topological_levels(apps)
    end

    test "raises Mix.Error with actionable message on a real cycle" do
      apps = [
        %App{name: "a", path: "p/a", version: "1.0.0", deps: ["b"]},
        %App{name: "b", path: "p/b", version: "1.0.0", deps: ["a"]}
      ]

      assert_raise Mix.Error, ~r/[Cc]ircular dependency.*\ba\b.*\bb\b/s, fn ->
        Graph.topological_levels(apps)
      end
    end
  end

  describe "transitive_deps/2" do
    test "resolves full transitive closure" do
      graph = Graph.build(@apps)
      deps = Graph.transitive_deps(["xml"], graph)

      assert MapSet.member?(deps, "xml")
      assert MapSet.member?(deps, "csd")
      assert MapSet.member?(deps, "openssl")
      assert MapSet.member?(deps, "transform")
      assert MapSet.member?(deps, "catalogos")
      refute MapSet.member?(deps, "auth")
    end

    test "single app with no deps" do
      graph = Graph.build(@apps)
      deps = Graph.transitive_deps(["openssl"], graph)
      assert deps == MapSet.new(["openssl"])
    end
  end

  describe "transitive_dependents/2" do
    test "resolves all dependents recursively (upstream)" do
      deps = Graph.transitive_dependents(["csd"], @apps)

      # csd itself
      assert MapSet.member?(deps, "csd")
      # xml depends on csd
      assert MapSet.member?(deps, "xml")
      # auth depends on csd
      assert MapSet.member?(deps, "auth")
      # cancelacion depends on auth (transitive)
      assert MapSet.member?(deps, "cancelacion")
      # openssl does NOT depend on csd (csd depends on openssl, not the other way)
      refute MapSet.member?(deps, "openssl")
      # transform does NOT depend on csd
      refute MapSet.member?(deps, "transform")
    end

    test "app with no dependents returns only itself" do
      deps = Graph.transitive_dependents(["cancelacion"], @apps)
      assert deps == MapSet.new(["cancelacion"])
    end

    test "leaf app with no dependents" do
      deps = Graph.transitive_dependents(["xml"], @apps)
      # xml has no dependents in our test data
      assert deps == MapSet.new(["xml"])
    end

    test "multiple starting apps" do
      deps = Graph.transitive_dependents(["openssl", "catalogos"], @apps)

      # openssl dependents: csd, xml, auth, cancelacion
      assert MapSet.member?(deps, "csd")
      assert MapSet.member?(deps, "xml")
      # catalogos dependents: xml
      assert MapSet.member?(deps, "xml")
      # the starting apps themselves
      assert MapSet.member?(deps, "openssl")
      assert MapSet.member?(deps, "catalogos")
    end
  end

  describe "filter_levels/2" do
    test "filters to only required apps" do
      levels = Graph.topological_levels(@apps)
      required = MapSet.new(["openssl", "csd"])
      filtered = Graph.filter_levels(levels, required)

      assert [{0, ["openssl"]}, {1, ["csd"]}] = filtered
    end
  end

  describe "level_map/1" do
    test "multi-level input returns name => level map" do
      levels = [{0, ["c", "d"]}, {1, ["b"]}, {2, ["a"]}]
      assert Graph.level_map(levels) == %{"a" => 2, "b" => 1, "c" => 0, "d" => 0}
    end

    test "empty input returns empty map" do
      assert Graph.level_map([]) == %{}
    end

    test "single level (all leaves)" do
      levels = [{0, ["x", "y"]}]
      assert Graph.level_map(levels) == %{"x" => 0, "y" => 0}
    end
  end

  describe "dep_count/2" do
    test "known name with deps returns count" do
      graph = %{"a" => ["b", "c"], "b" => ["c"], "c" => []}
      assert Graph.dep_count("a", graph) == 2
    end

    test "known name with no deps returns 0" do
      graph = %{"a" => ["b"], "b" => []}
      assert Graph.dep_count("b", graph) == 0
    end

    test "unknown name returns 0" do
      graph = %{"a" => ["b"]}
      assert Graph.dep_count("z", graph) == 0
    end
  end

  describe "deep_count/2" do
    test "3-node chain: a→b→c — a has 1, b has 0" do
      graph = %{"a" => ["b"], "b" => ["c"], "c" => []}
      assert Graph.deep_count("a", graph) == 1
      assert Graph.deep_count("b", graph) == 0
    end

    test "leaf node returns 0" do
      graph = %{"a" => ["b"], "b" => []}
      assert Graph.deep_count("b", graph) == 0
    end

    test "unknown name returns 0" do
      graph = %{"a" => ["b"]}
      assert Graph.deep_count("z", graph) == 0
    end

    test "multiple qualifying direct deps" do
      graph = %{"root" => ["x", "y", "z"], "x" => ["a"], "y" => ["b"], "z" => []}
      assert Graph.deep_count("root", graph) == 2
    end
  end
end
