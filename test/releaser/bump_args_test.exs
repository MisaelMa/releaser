defmodule Releaser.BumpArgsTest do
  use ExUnit.Case, async: true

  alias Releaser.{App, BumpArgs}

  @single_app [
    %App{name: "releaser", path: ".", version: "0.0.1", deps: [], version_form: :attribute}
  ]

  @multi_app [
    %App{name: "xml", path: "apps/cfdi/xml", version: "1.0.0", deps: []},
    %App{name: "csd", path: "apps/cfdi/csd", version: "1.0.0", deps: []},
    %App{name: "auth", path: "apps/sat/auth", version: "1.0.0", deps: []}
  ]

  describe "validate_opts/1" do
    test "ok without --mode or --tag" do
      assert BumpArgs.validate_opts([]) == :ok
    end

    test "ok with --mode prerelease and --tag" do
      assert BumpArgs.validate_opts(mode: "prerelease", tag: "dev") == :ok
    end

    test "rejects --mode prerelease without --tag" do
      assert BumpArgs.validate_opts(mode: "prerelease") ==
               {:error, :prerelease_requires_tag}
    end

    test "rejects unknown --mode" do
      assert BumpArgs.validate_opts(mode: "nope") == {:error, {:unknown_mode, "nope"}}
    end
  end

  describe "resolve_command/3 — single-app inference" do
    test "infers app name when only `patch` is given" do
      assert BumpArgs.resolve_command(["patch"], @single_app, []) ==
               {:ok, {:bump, "releaser", :patch}}
    end

    test "infers app name when only `minor` is given" do
      assert BumpArgs.resolve_command(["minor"], @single_app, []) ==
               {:ok, {:bump, "releaser", :minor}}
    end

    test "infers app name when only `major` is given" do
      assert BumpArgs.resolve_command(["major"], @single_app, []) ==
               {:ok, {:bump, "releaser", :major}}
    end

    test "infers app name for `release`" do
      assert BumpArgs.resolve_command(["release"], @single_app, []) ==
               {:ok, {:release, "releaser"}}
    end

    test "infers app name for explicit version string" do
      assert BumpArgs.resolve_command(["2.0.0"], @single_app, []) ==
               {:ok, {:explicit, "releaser", "2.0.0"}}
    end

    test "infers app name when positional is empty and --mode prerelease is given" do
      opts = [mode: "prerelease", tag: "dev"]

      assert BumpArgs.resolve_command([], @single_app, opts) ==
               {:ok, {:prerelease_only, "releaser"}}
    end
  end

  describe "resolve_command/3 — explicit app name" do
    test "accepts explicit app name with bump type" do
      assert BumpArgs.resolve_command(["xml", "minor"], @multi_app, []) ==
               {:ok, {:bump, "xml", :minor}}
    end

    test "accepts explicit app name with release" do
      assert BumpArgs.resolve_command(["xml", "release"], @multi_app, []) ==
               {:ok, {:release, "xml"}}
    end

    test "accepts explicit app name with version" do
      assert BumpArgs.resolve_command(["xml", "3.1.4"], @multi_app, []) ==
               {:ok, {:explicit, "xml", "3.1.4"}}
    end
  end

  describe "resolve_command/3 — error paths" do
    test "multi-app without name returns :ambiguous_app" do
      assert BumpArgs.resolve_command(["patch"], @multi_app, []) ==
               {:error, :ambiguous_app}
    end

    test "multi-app with no positionals and no mode → ambiguous" do
      assert BumpArgs.resolve_command([], @multi_app, []) ==
               {:error, :ambiguous_app}
    end

    test "unknown app name returns :app_not_found" do
      assert BumpArgs.resolve_command(["nonexistent", "patch"], @multi_app, []) ==
               {:error, {:app_not_found, "nonexistent"}}
    end

    test "too many positionals returns :usage" do
      assert BumpArgs.resolve_command(["xml", "minor", "extra"], @multi_app, []) ==
               {:error, :usage}
    end

    test "empty positionals in single-app without --mode returns :usage" do
      assert BumpArgs.resolve_command([], @single_app, []) == {:error, :usage}
    end
  end
end
