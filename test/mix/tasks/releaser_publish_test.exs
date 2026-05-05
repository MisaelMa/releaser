defmodule Mix.Tasks.Releaser.PublishTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Releaser.Publish

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

  describe "render_skipped/1 — :blocked_by_deps" do
    test "names the blocked app and lists its blocking deps" do
      Publish.render_skipped([
        %{
          app: "csd",
          local: "2.0.0",
          hex: nil,
          reason: :blocked_by_deps,
          blocked_by: ["openssl"]
        }
      ])

      output = collect_output() |> strip_ansi()

      assert output =~ "csd"
      assert output =~ "blocked"
      assert output =~ "openssl"
    end

    test "joins multiple blocking deps with comma" do
      Publish.render_skipped([
        %{
          app: "a",
          local: "1.0.0",
          hex: nil,
          reason: :blocked_by_deps,
          blocked_by: ["x", "y"]
        }
      ])

      output = collect_output() |> strip_ansi()

      assert output =~ "x, y"
    end

    test "renders blocked entry alongside :already_published distinctly" do
      Publish.render_skipped([
        %{
          app: "csd",
          local: "2.0.0",
          hex: nil,
          reason: :blocked_by_deps,
          blocked_by: ["openssl"]
        },
        %{app: "safe", local: "1.0.0", hex: "1.0.0", reason: :already_published}
      ])

      output = collect_output() |> strip_ansi()

      assert output =~ "csd"
      assert output =~ "blocked"
      assert output =~ "openssl"

      assert output =~ "safe"
      assert output =~ "already on Hex"
    end

    test "renders :prerelease branch unchanged" do
      Publish.render_skipped([
        %{app: "lib", local: "1.0.0-rc1", hex: nil, reason: :prerelease}
      ])

      output = collect_output() |> strip_ansi()

      assert output =~ "lib"
      assert output =~ "pre-release"
    end
  end

  describe "render_skipped/1 — empty" do
    test "no output when skipped list is empty" do
      Publish.render_skipped([])

      output = collect_output()
      assert output == ""
    end
  end
end
