defmodule Releaser.Config do
  @moduledoc """
  Configuration schema and defaults for Releaser.

  All configuration lives under the `:releaser` key in your root `mix.exs` project config.

  ## Options

  - `:apps_root` — Root directory containing your apps. Default: `"apps"`
  - `:version_files` — List of `{glob_or_path, regex}` tuples for multi-file version sync
  - `:changelog` — Changelog configuration (see below)
  - `:hooks` — Pre/post hook modules (see below)
  - `:publisher` — Hex publishing configuration (see below)

  ## Changelog options

  - `:anchors` — Map of commit prefix to changelog section.
    Default: `%{"feat" => "Added", "fix" => "Fixed", "refactor" => "Changed", "docs" => "Documentation", "perf" => "Performance", "breaking" => "Breaking Changes"}`
  - `:path` — Path to CHANGELOG.md. Default: `"CHANGELOG.md"`
  - `:format` — `:keepachangelog` (default)

  ## Hooks options

  - `:pre` — List of modules implementing `Releaser.Hooks.PreHook`
  - `:post` — List of modules implementing `Releaser.Hooks.PostHook`

  ## Publisher options

  - `:org` — Hex organization name (optional)
  - `:package_defaults` — Default `package/0` config injected into apps that lack it.
    Keys: `:licenses`, `:links`, `:files`

  ## Commits (Conventional Commits)

  Opt-in automation that parses `git log` to decide bump types per app.
  Disabled unless you set `enabled: true`.

      commits: [
        enabled: true,
        bump_rules: %{"feat" => :minor, "fix" => :patch, ...},
        breaking_bump: :major,
        breaking_markers: [:bang, :body],
        scope_aliases: %{"xml" => "cfdi_xml"},
        no_scope: :warn
      ]

  See `Releaser.Commits` and `guides/conventional-commits.md`.
  """

  @defaults %{
    apps_root: "apps",
    version_files: [],
    changelog: %{
      path: "CHANGELOG.md",
      format: :keepachangelog,
      anchors: %{
        "feat" => "Added",
        "fix" => "Fixed",
        "refactor" => "Changed",
        "docs" => "Documentation",
        "perf" => "Performance",
        "breaking" => "Breaking Changes"
      }
    },
    hooks: %{
      pre: [],
      post: []
    },
    publisher: %{
      org: nil,
      package_defaults: %{
        licenses: ["MIT"],
        links: %{},
        files: ~w(lib mix.exs README.md LICENSE)
      }
    },
    commits: %{
      enabled: false,
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
      no_scope: :warn,
      validation: %{
        strict_types: false,
        strict_scopes: false,
        allowed_types: ~w[docs chore test style build ci],
        allowed_scopes: nil,
        allow_no_scope: true,
        max_subject_length: 100
      }
    }
  }

  @doc """
  Loads configuration from the host project's mix.exs, merged with defaults.
  """
  def load do
    user_config =
      if function_exported?(Mix.Project, :config, 0) do
        Mix.Project.config() |> Keyword.get(:releaser, []) |> to_map()
      else
        %{}
      end

    deep_merge(@defaults, user_config)
  end

  @doc """
  Returns the default configuration.
  """
  def defaults, do: @defaults

  defp to_map(list) when is_list(list) do
    if Keyword.keyword?(list) do
      Map.new(list, fn {k, v} -> {k, to_map(v)} end)
    else
      list
    end
  end

  defp to_map(other), do: other

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, base_val, override_val when is_map(base_val) and is_map(override_val) ->
        deep_merge(base_val, override_val)

      _key, _base_val, override_val ->
        override_val
    end)
  end

  defp deep_merge(_base, override), do: override
end
