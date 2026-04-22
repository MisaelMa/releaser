defmodule Releaser.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Releaser.Workspace

  @literal_mix """
  defmodule MyApp.MixProject do
    use Mix.Project

    def project do
      [
        app: :my_app,
        version: "1.2.3",
        elixir: "~> 1.15",
        deps: deps()
      ]
    end

    defp deps, do: []
  end
  """

  @attribute_mix """
  defmodule MyLib.MixProject do
    use Mix.Project

    @version "4.5.6"

    def project do
      [
        app: :my_lib,
        version: @version,
        elixir: "~> 1.15",
        deps: deps()
      ]
    end

    defp deps, do: []
  end
  """

  @publishable_mix """
  defmodule MyPub.MixProject do
    use Mix.Project

    def project do
      [
        app: :my_pub,
        version: "0.1.0",
        releaser: [publish: true],
        deps: deps()
      ]
    end

    defp deps, do: [{:other, path: "../other"}]
  end
  """

  describe "discover/1 — nested apps layout" do
    setup do
      root = make_tmp_root()
      write_mix!(root, "apps/group/literal/mix.exs", @literal_mix)
      write_mix!(root, "apps/group/attribute/mix.exs", @attribute_mix)
      write_mix!(root, "apps/group/publishable/mix.exs", @publishable_mix)
      %{root: root}
    end

    test "extracts version with :literal form", %{root: root} do
      apps = Workspace.discover(apps_root: Path.join(root, "apps"))
      literal = Enum.find(apps, &(&1.name == "my_app"))

      assert literal.version == "1.2.3"
      assert literal.version_form == :literal
    end

    test "extracts version with :attribute form", %{root: root} do
      apps = Workspace.discover(apps_root: Path.join(root, "apps"))
      attribute = Enum.find(apps, &(&1.name == "my_lib"))

      assert attribute.version == "4.5.6"
      assert attribute.version_form == :attribute
    end

    test "marks apps with releaser.publish as publishable", %{root: root} do
      apps = Workspace.discover(apps_root: Path.join(root, "apps"))
      pub = Enum.find(apps, &(&1.name == "my_pub"))

      assert pub.publish == true
      refute Enum.find(apps, &(&1.name == "my_app")).publish
    end
  end

  describe "discover/1 — single-app layout (apps_root = \".\")" do
    test "includes the root mix.exs" do
      root = make_tmp_root()
      File.write!(Path.join(root, "mix.exs"), @attribute_mix)

      apps =
        File.cd!(root, fn ->
          Workspace.discover(apps_root: ".")
        end)

      assert length(apps) == 1
      [app] = apps
      assert app.name == "my_lib"
      assert app.version == "4.5.6"
      assert app.version_form == :attribute
    end
  end

  describe "discover/1 — ignored paths" do
    test "skips mix.exs under _build, deps, doc, and dotted dirs" do
      root = make_tmp_root()

      File.write!(Path.join(root, "mix.exs"), @attribute_mix)
      write_mix!(root, "_build/dev/lib/foo/mix.exs", @literal_mix)
      write_mix!(root, "deps/earmark/mix.exs", @literal_mix)
      write_mix!(root, "doc/sample/mix.exs", @literal_mix)
      write_mix!(root, ".elixir_ls/leftover/mix.exs", @literal_mix)

      apps =
        File.cd!(root, fn ->
          Workspace.discover(apps_root: ".")
        end)

      assert length(apps) == 1
      assert hd(apps).name == "my_lib"
    end
  end

  describe "discover/1 — path deps resolution" do
    test "keeps only path deps that refer to other discovered apps" do
      root = make_tmp_root()
      write_mix!(root, "apps/publishable/mix.exs", @publishable_mix)
      # Not creating "other" → the path dep should be dropped
      apps = Workspace.discover(apps_root: Path.join(root, "apps"))
      pub = Enum.find(apps, &(&1.name == "my_pub"))

      assert pub.deps == []
    end
  end

  # Helpers

  defp make_tmp_root do
    path = Path.join(System.tmp_dir!(), "releaser_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit_cleanup(path)
    path
  end

  defp write_mix!(root, rel_path, content) do
    full = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  defp on_exit_cleanup(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
  end
end
