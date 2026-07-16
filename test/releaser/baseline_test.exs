defmodule Releaser.BaselineTest do
  use ExUnit.Case, async: true

  alias Releaser.{Baseline, App}

  @app %App{
    name: "ex_pdf",
    path: "apps/ex_pdf",
    version: "1.0.7",
    deps: [],
    publish: true
  }

  defp source(value), do: fn _app -> value end

  describe "resolve/2 — fallback chain" do
    test "returns the first source that yields a version" do
      assert Baseline.resolve(@app, sources: [source("1.0.6"), source("1.0.1")]) == "1.0.6"
    end

    test "falls through to the next source when one yields nil" do
      assert Baseline.resolve(@app, sources: [source(nil), source("1.0.5")]) == "1.0.5"
    end

    test "returns nil when no source yields a version" do
      assert Baseline.resolve(@app, sources: [source(nil), source(nil)]) == nil
    end

    test "returns nil when the source list is empty" do
      assert Baseline.resolve(@app, sources: []) == nil
    end

    test "does not consult later sources once one resolves" do
      me = self()

      first = fn _app -> "1.0.6" end
      second = fn _app -> send(me, :second_called) && nil end

      assert Baseline.resolve(@app, sources: [first, second]) == "1.0.6"
      refute_received :second_called
    end

    test "skips a source that yields an unparseable version" do
      # e.g. a malformed git tag like `ex_pdf-vlatest`
      assert Baseline.resolve(@app, sources: [source("latest"), source("1.0.6")]) == "1.0.6"
    end

    test "passes the app struct to each source" do
      from_struct = fn app -> "0.0.#{String.length(app.name)}" end

      assert Baseline.resolve(@app, sources: [from_struct]) == "0.0.6"
    end
  end

  describe "resolve_many/2" do
    test "builds a name => baseline map" do
      apps = [
        @app,
        %App{name: "ex_qr", path: "apps/ex_qr", version: "0.1.0", deps: [], publish: true}
      ]

      by_name = fn app -> if app.name == "ex_pdf", do: "1.0.6", else: "0.0.9" end

      assert Baseline.resolve_many(apps, sources: [by_name]) == %{
               "ex_pdf" => "1.0.6",
               "ex_qr" => "0.0.9"
             }
    end

    test "keeps apps with no baseline as nil entries" do
      assert Baseline.resolve_many([@app], sources: [source(nil)]) == %{"ex_pdf" => nil}
    end

    test "returns an empty map for no apps" do
      assert Baseline.resolve_many([], sources: [source("1.0.0")]) == %{}
    end

    test "consults each app exactly once" do
      me = self()
      counting = fn app -> send(me, {:called, app.name}) && "1.0.0" end

      Baseline.resolve_many([@app, @app], sources: [counting])

      assert_received {:called, "ex_pdf"}
      refute_received {:called, "ex_pdf"}
    end
  end

  describe "highest_version/2 — git tag source parsing" do
    test "extracts the highest version from app-scoped tags" do
      tags = ["ex_pdf-v1.0.5", "ex_pdf-v1.0.7", "ex_pdf-v1.0.6"]

      assert Baseline.highest_version(tags, "ex_pdf") == "1.0.7"
    end

    test "compares semantically, not lexicographically" do
      tags = ["ex_pdf-v1.0.9", "ex_pdf-v1.0.10"]

      assert Baseline.highest_version(tags, "ex_pdf") == "1.0.10"
    end

    test "ignores tags belonging to other apps" do
      tags = ["ex_qr-v9.9.9", "ex_pdf-v1.0.6"]

      assert Baseline.highest_version(tags, "ex_pdf") == "1.0.6"
    end

    test "does not confuse an app with a name that is a prefix of another" do
      tags = ["ex_pdf_components-v2.0.0", "ex_pdf-v1.0.6"]

      assert Baseline.highest_version(tags, "ex_pdf") == "1.0.6"
      assert Baseline.highest_version(tags, "ex_pdf_components") == "2.0.0"
    end

    test "ignores malformed tags" do
      tags = ["ex_pdf-vlatest", "ex_pdf-v1.0.6"]

      assert Baseline.highest_version(tags, "ex_pdf") == "1.0.6"
    end

    test "ranks a pre-release above the stable release it supersedes" do
      tags = ["ex_pdf-v1.0.6", "ex_pdf-v1.0.7-dev.1"]

      assert Baseline.highest_version(tags, "ex_pdf") == "1.0.7-dev.1"
    end

    test "returns nil when no tag matches" do
      assert Baseline.highest_version(["ex_qr-v1.0.0"], "ex_pdf") == nil
      assert Baseline.highest_version([], "ex_pdf") == nil
    end
  end
end
