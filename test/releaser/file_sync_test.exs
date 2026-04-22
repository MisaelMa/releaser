defmodule Releaser.FileSyncTest do
  use ExUnit.Case, async: true

  alias Releaser.FileSync

  @literal_mix """
  defmodule MyApp.MixProject do
    use Mix.Project

    def project do
      [
        app: :my_app,
        version: "1.2.3",
        deps: []
      ]
    end
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
        deps: []
      ]
    end
  end
  """

  describe "update_mix_version/4" do
    test "rewrites the literal `version: \"X\"` token" do
      app_path = write_mix!(@literal_mix)

      FileSync.update_mix_version(app_path, "1.2.3", "1.2.4")

      updated = File.read!(Path.join(app_path, "mix.exs"))
      assert updated =~ ~s(version: "1.2.4")
      refute updated =~ ~s(version: "1.2.3")
    end

    test "rewrites the `@version \"X\"` attribute when form is :attribute" do
      app_path = write_mix!(@attribute_mix)

      FileSync.update_mix_version(app_path, "4.5.6", "4.5.7", :attribute)

      updated = File.read!(Path.join(app_path, "mix.exs"))
      assert updated =~ ~s(@version "4.5.7")
      refute updated =~ ~s(@version "4.5.6")
      # The `version: @version` reference stays untouched
      assert updated =~ "version: @version"
    end

    test "is a no-op when the old version is not present" do
      app_path = write_mix!(@literal_mix)

      FileSync.update_mix_version(app_path, "9.9.9", "1.0.0")

      updated = File.read!(Path.join(app_path, "mix.exs"))
      assert updated == @literal_mix
    end

    test "defaults to :literal form when form is omitted" do
      app_path = write_mix!(@literal_mix)

      FileSync.update_mix_version(app_path, "1.2.3", "2.0.0")

      updated = File.read!(Path.join(app_path, "mix.exs"))
      assert updated =~ ~s(version: "2.0.0")
    end
  end

  describe "sync_files/4" do
    test "updates versions in additional files matching the regex" do
      app_path = write_mix!(@literal_mix)
      File.write!(Path.join(app_path, "README.md"), ~s(Current version "1.2.3" is stable\n))

      FileSync.sync_files(app_path, "1.2.3", "1.2.4", [
        {"README.md", ~r/version "(\d+\.\d+\.\d+)"/}
      ])

      updated = File.read!(Path.join(app_path, "README.md"))
      assert updated =~ ~s(version "1.2.4")
      refute updated =~ ~s(version "1.2.3")
    end

    test "skips files that don't exist" do
      app_path = write_mix!(@literal_mix)

      # Should not raise
      FileSync.sync_files(app_path, "1.2.3", "1.2.4", [
        {"nonexistent.md", ~r/version "(\d+\.\d+\.\d+)"/}
      ])
    end
  end

  # Helpers

  defp write_mix!(content) do
    path = Path.join(System.tmp_dir!(), "releaser_fs_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.write!(Path.join(path, "mix.exs"), content)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
