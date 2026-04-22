defmodule Releaser.CommitsTest do
  use ExUnit.Case, async: true

  alias Releaser.{App, Commits}

  @default_config %{
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
    scope_aliases: %{},
    no_scope: :ignore
  }

  @apps [
    %App{name: "xml", path: "apps/cfdi/xml", version: "4.0.18", deps: []},
    %App{name: "csd", path: "apps/cfdi/csd", version: "4.0.16", deps: []},
    %App{name: "auth", path: "apps/sat/auth", version: "1.0.1", deps: []},
    %App{name: "releaser", path: ".", version: "0.0.1", deps: []}
  ]

  # Helpers -----------------------------------------------------------

  defp raw_log(commits) do
    Enum.map_join(commits, "---COMMIT---\n", fn {sha, header, body} ->
      "#{sha} #{header}\n#{body}"
    end) <> "---COMMIT---\n"
  end

  defp plan(raw, overrides \\ %{}) do
    config = Map.merge(@default_config, overrides)

    Commits.plan(
      apps: @apps,
      config: config,
      since: "v0.0.0",
      git_log: fn _ -> raw end
    )
  end

  # Tests -------------------------------------------------------------

  describe "parse_log/2" do
    test "parses a simple feat commit with scope" do
      raw = raw_log([{"abc123", "feat(xml): add carta_porte 3.1", ""}])

      [commit] = Commits.parse_log(raw, @default_config)

      assert commit.sha == "abc123"
      assert commit.type == "feat"
      assert commit.scope == "xml"
      assert commit.subject == "add carta_porte 3.1"
      assert commit.breaking == false
      assert commit.bump == :minor
    end

    test "parses a fix commit" do
      raw = raw_log([{"abc", "fix(csd): handle empty key", ""}])
      [commit] = Commits.parse_log(raw, @default_config)
      assert commit.bump == :patch
    end

    test "detects breaking via !" do
      raw = raw_log([{"abc", "feat(xml)!: rewrite signer", ""}])
      [commit] = Commits.parse_log(raw, @default_config)

      assert commit.breaking == true
      assert commit.bump == :major
    end

    test "detects breaking via body marker (space)" do
      raw =
        raw_log([
          {"abc", "feat(xml): new thing",
           "BREAKING CHANGE: old CFDI.sign/2 was renamed to CFDI.sign_with_csd/2"}
        ])

      [commit] = Commits.parse_log(raw, @default_config)
      assert commit.breaking == true
      assert commit.bump == :major
    end

    test "detects breaking via body marker (hyphen)" do
      raw =
        raw_log([
          {"abc", "feat(xml): new thing", "BREAKING-CHANGE: hyphenated form"}
        ])

      [commit] = Commits.parse_log(raw, @default_config)
      assert commit.breaking == true
    end

    test "rejects lowercase breaking marker (spec v1.0.0 requires uppercase)" do
      raw =
        raw_log([
          {"abc", "feat(xml): new thing", "breaking change: lowercase is invalid per spec"}
        ])

      [commit] = Commits.parse_log(raw, @default_config)
      assert commit.breaking == false
      assert commit.bump == :minor
    end

    test "rejects mixed case breaking marker" do
      raw =
        raw_log([
          {"abc", "feat(xml): new thing", "Breaking Change: mixed case is invalid"}
        ])

      [commit] = Commits.parse_log(raw, @default_config)
      assert commit.breaking == false
    end

    test "parses commit without scope" do
      raw = raw_log([{"abc", "chore: bump deps", ""}])
      [commit] = Commits.parse_log(raw, @default_config)

      assert commit.scope == nil
    end

    test "types outside bump_rules produce :none" do
      raw = raw_log([{"abc", "docs(xml): fix typo", ""}])
      [commit] = Commits.parse_log(raw, @default_config)

      assert commit.bump == :none
    end

    test "skips non-conventional commits" do
      raw = raw_log([{"abc", "this is not conventional", ""}])
      assert Commits.parse_log(raw, @default_config) == []
    end

    test "breaking_markers: [:bang] ignores body markers" do
      config = %{@default_config | breaking_markers: [:bang]}

      raw =
        raw_log([
          {"abc", "feat(xml): thing", "BREAKING CHANGE: body marker"}
        ])

      [commit] = Commits.parse_log(raw, config)
      assert commit.breaking == false
      assert commit.bump == :minor
    end

    test "breaking_markers: [:body] ignores bang" do
      config = %{@default_config | breaking_markers: [:body]}
      raw = raw_log([{"abc", "feat(xml)!: thing", ""}])
      [commit] = Commits.parse_log(raw, config)
      assert commit.breaking == false
    end
  end

  describe "plan/1 — aggregation" do
    test "single feat produces minor for that app" do
      raw = raw_log([{"abc", "feat(xml): add X", ""}])
      [entry] = plan(raw)

      assert entry.app == "xml"
      assert entry.bump == :minor
      assert length(entry.commits) == 1
    end

    test "10 feats produce a single minor bump" do
      commits = for i <- 1..10, do: {"sha#{i}", "feat(xml): feature #{i}", ""}
      raw = raw_log(commits)
      [entry] = plan(raw)

      assert entry.bump == :minor
      assert length(entry.commits) == 10
    end

    test "feat + fix → minor wins" do
      raw =
        raw_log([
          {"a", "fix(xml): bug", ""},
          {"b", "feat(xml): feature", ""},
          {"c", "fix(xml): bug2", ""}
        ])

      [entry] = plan(raw)
      assert entry.bump == :minor
    end

    test "one breaking among many wins major" do
      raw =
        raw_log([
          {"a", "fix(xml): small", ""},
          {"b", "feat(xml): thing", ""},
          {"c", "feat(xml)!: breaking!", ""},
          {"d", "fix(xml): another", ""}
        ])

      [entry] = plan(raw)
      assert entry.bump == :major
    end

    test "groups commits by app" do
      raw =
        raw_log([
          {"a", "feat(xml): x", ""},
          {"b", "fix(csd): c", ""},
          {"c", "feat(auth)!: a", ""}
        ])

      result = plan(raw)
      by_app = Map.new(result, &{&1.app, &1.bump})

      assert by_app == %{
               "xml" => :minor,
               "csd" => :patch,
               "auth" => :major
             }
    end
  end

  describe "plan/1 — no-op behavior" do
    test "returns [] when there are no commits" do
      assert plan("") == []
    end

    test "returns [] when all commits are docs/chore" do
      raw =
        raw_log([
          {"a", "docs(xml): typo", ""},
          {"b", "chore(csd): cleanup", ""}
        ])

      assert plan(raw) == []
    end

    test "ignores commits whose scope doesn't match any app" do
      raw = raw_log([{"a", "feat(nonexistent): thing", ""}])
      assert plan(raw) == []
    end

    test "apps without relevant commits are omitted from the plan" do
      raw = raw_log([{"a", "feat(xml): only xml", ""}])
      result = plan(raw)

      assert length(result) == 1
      assert hd(result).app == "xml"
    end
  end

  describe "plan/1 — scope resolution" do
    test "uses scope_aliases for non-matching scopes" do
      raw = raw_log([{"a", "feat(autenticacion): thing", ""}])
      overrides = %{scope_aliases: %{"autenticacion" => "auth"}}
      [entry] = plan(raw, overrides)
      assert entry.app == "auth"
    end

    test "falls back to prefix-stripping (cfdi_xml ↔ xml)" do
      apps = [
        %App{name: "cfdi_xml", path: "apps/cfdi/xml", version: "4.0.18", deps: []}
      ]

      raw = raw_log([{"a", "feat(xml): thing", ""}])

      [entry] =
        Commits.plan(
          apps: apps,
          config: @default_config,
          since: "v0",
          git_log: fn _ -> raw end
        )

      assert entry.app == "cfdi_xml"
    end
  end

  describe "plan/1 — no_scope handling" do
    test ":ignore drops commits without scope silently" do
      raw =
        raw_log([
          {"a", "feat: without scope", ""},
          {"b", "feat(xml): with scope", ""}
        ])

      result = plan(raw, %{no_scope: :ignore})
      assert length(result) == 1
      assert hd(result).app == "xml"
    end

    test "{:apply_to, app} routes scopeless commits to that app" do
      raw =
        raw_log([
          {"a", "feat: global feature", ""},
          {"b", "fix: global fix", ""}
        ])

      [entry] = plan(raw, %{no_scope: {:apply_to, "releaser"}})

      assert entry.app == "releaser"
      assert entry.bump == :minor
      assert length(entry.commits) == 2
    end

    test "{:apply_to, unknown} drops commits when target does not exist" do
      raw = raw_log([{"a", "feat: global", ""}])
      assert plan(raw, %{no_scope: {:apply_to, "nonexistent"}}) == []
    end
  end
end
