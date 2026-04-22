defmodule Releaser.PublisherTest do
  use ExUnit.Case, async: false

  alias Releaser.Publisher

  @mix_template """
  defmodule <%= MODULE %>.MixProject do
    use Mix.Project

    def project do
      [
        app: :<%= APP %>,
        version: "<%= VERSION %>",
        releaser: [publish: true],
        deps: []
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

  defp write_app!(root, name, version) do
    app_dir = Path.join([root, "apps", name])
    File.mkdir_p!(app_dir)

    content =
      @mix_template
      |> String.replace("<%= MODULE %>", Macro.camelize(name))
      |> String.replace("<%= APP %>", name)
      |> String.replace("<%= VERSION %>", version)

    File.write!(Path.join(app_dir, "mix.exs"), content)
  end

  defp plan(root, statuses) do
    File.cd!(root, fn ->
      Publisher.plan(apps_root: "apps", statuses: statuses)
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
end
