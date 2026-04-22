defmodule Releaser.CommitValidatorTest do
  use ExUnit.Case, async: true

  alias Releaser.{App, CommitValidator}

  @apps [
    %App{name: "releaser", path: ".", version: "0.0.1", deps: []}
  ]

  @base_config %{
    enabled: true,
    bump_rules: %{
      "feat" => :minor,
      "fix" => :patch,
      "perf" => :patch,
      "refactor" => :patch,
      "revert" => :patch
    },
    breaking_bump: :major,
    breaking_markers: [:bang, :body],
    scope_aliases: %{"rel" => "releaser"},
    no_scope: :ignore,
    validation: %{
      strict_types: false,
      strict_scopes: false,
      allowed_types: ~w[docs chore test style build ci],
      allowed_scopes: nil,
      allow_no_scope: true,
      max_subject_length: 100
    }
  }

  defp v(msg, overrides \\ %{}) do
    validation = Map.merge(@base_config.validation, overrides)
    config = %{@base_config | validation: validation}
    CommitValidator.validate(msg, config, apps: @apps)
  end

  describe "format" do
    test "accepts valid Conventional Commit" do
      assert v("feat(releaser): add hooks") == :ok
    end

    test "accepts without scope" do
      assert v("chore: bump deps") == :ok
    end

    test "accepts with bang" do
      assert v("feat(releaser)!: breaking change") == :ok
    end

    test "accepts multi-scope" do
      assert v("feat(releaser, rel): thing") == :ok
    end

    test "rejects non-conventional format" do
      assert {:error, :bad_format} = v("fix stuff")
    end

    test "rejects missing subject" do
      assert {:error, :bad_format} = v("feat(releaser):")
    end

    test "rejects empty message" do
      assert {:error, :missing_header} = v("")
    end

    test "skips comment lines (git templates)" do
      msg = """
      # Please enter the commit message for your changes.
      # Lines starting with '#' will be ignored.

      feat(releaser): real subject
      """

      assert v(msg) == :ok
    end
  end

  describe "strict_types" do
    test "rejects unknown type when strict" do
      assert {:error, {:unknown_type, "foo", _}} =
               v("foo(releaser): bar", %{strict_types: true})
    end

    test "accepts bump_rules types when strict" do
      assert v("feat(releaser): x", %{strict_types: true}) == :ok
      assert v("fix(releaser): x", %{strict_types: true}) == :ok
      assert v("perf(releaser): x", %{strict_types: true}) == :ok
    end

    test "accepts allowed_types when strict" do
      assert v("docs(releaser): x", %{strict_types: true}) == :ok
      assert v("chore(releaser): x", %{strict_types: true}) == :ok
      assert v("ci(releaser): x", %{strict_types: true}) == :ok
    end

    test "permissive mode accepts any type" do
      assert v("whatever(releaser): x") == :ok
    end
  end

  describe "strict_scopes" do
    test "rejects unknown scope when strict" do
      assert {:error, {:unknown_scope, "xml", _}} =
               v("feat(xml): bad", %{strict_scopes: true})
    end

    test "accepts app name as scope" do
      assert v("feat(releaser): ok", %{strict_scopes: true}) == :ok
    end

    test "accepts alias as scope" do
      assert v("feat(rel): ok", %{strict_scopes: true}) == :ok
    end

    test "rejects one bad scope in multi-scope" do
      assert {:error, {:unknown_scope, "foo", _}} =
               v("feat(releaser,foo): bad", %{strict_scopes: true})
    end

    test "explicit allowed_scopes list overrides inference" do
      assert v("feat(anything): ok", %{
               strict_scopes: true,
               allowed_scopes: ["anything"]
             }) == :ok
    end

    test "permissive mode accepts any scope" do
      assert v("feat(whatever): x") == :ok
    end
  end

  describe "allow_no_scope" do
    test "rejects scopeless commits when disabled" do
      assert {:error, :scope_required} =
               v("feat: thing", %{allow_no_scope: false})
    end

    test "accepts scopeless commits by default" do
      assert v("feat: thing") == :ok
    end
  end

  describe "max_subject_length" do
    test "rejects subjects longer than limit" do
      long = String.duplicate("x", 101)
      assert {:error, {:subject_too_long, 101, 100}} = v("feat(releaser): #{long}")
    end

    test "accepts at exactly the limit" do
      at_limit = String.duplicate("x", 100)
      assert v("feat(releaser): #{at_limit}") == :ok
    end
  end

  describe "body separation (spec v1.0.0)" do
    test "accepts single-line commit (no body)" do
      assert v("feat(releaser): single line") == :ok
    end

    test "accepts header followed by blank line and body" do
      msg = """
      feat(releaser): add thing

      This is the body explaining what changed.
      """

      assert v(msg) == :ok
    end

    test "rejects body immediately after header without blank line" do
      msg = """
      feat(releaser): add thing
      This is the body without a blank line.
      """

      assert {:error, :missing_body_separator} = v(msg)
    end

    test "accepts header with trailing blank lines (still no body)" do
      msg = """
      feat(releaser): add thing


      """

      assert v(msg) == :ok
    end

    test "accepts header + blank line + multi-paragraph body" do
      msg = """
      feat(releaser): add thing

      First paragraph of body.

      Second paragraph with more details.

      BREAKING CHANGE: explains the breaking change.
      """

      assert v(msg) == :ok
    end
  end

  describe "resolve_allowed_scopes/2" do
    test "auto-infers from app names + aliases" do
      scopes = CommitValidator.resolve_allowed_scopes(@base_config, @apps)
      assert "releaser" in scopes
      assert "rel" in scopes
    end

    test "uses explicit list when configured" do
      config = put_in(@base_config.validation.allowed_scopes, ["custom"])
      assert CommitValidator.resolve_allowed_scopes(config, @apps) == ["custom"]
    end
  end
end
