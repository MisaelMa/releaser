defmodule Releaser.Baseline do
  @moduledoc """
  Resolves the *baseline* of an app: the last version that was actually released.

  A cascade bump is a relative operation — it only makes sense against a fixed
  reference point. Using the working-tree `mix.exs` version as that reference is
  wrong, because a bump mutates exactly that value: run two bumps before
  committing and the second one measures from the first one's output, bumping
  an app twice for a single release cycle.

  The baseline answers "what version of this app does the world already have?"
  and is resolved from the first source that knows, in descending authority:

    1. **Hex** — a published release is ground truth.
    2. **Git tags** — `<app>-v<version>`, as emitted by `Releaser.Hooks.GitTag`.
       Covers projects that commit and tag on bump but publish later.
    3. **Git HEAD** — the version in `mix.exs` at HEAD. Covers the common flow
       where bump leaves the working tree dirty and the commit comes later.

  When no source knows the app (never published, no tags, not in git), the
  baseline is `nil` and callers fall back to bumping unconditionally.

  ## Injecting sources

  `:sources` overrides the chain with a list of `(App.t() -> String.t() | nil)`
  functions. Tests use this to avoid touching the network or the repository.
  """

  alias Releaser.{Git, HexStatus, Version}

  @type source :: (Releaser.App.t() -> String.t() | nil)

  @default_timeout 30_000

  @doc """
  Resolves the baseline version of a single app, or `nil` when unknown.

  Sources are consulted in order and the first parseable version wins; a source
  returning `nil` or a malformed version falls through to the next.
  """
  def resolve(app, opts \\ []) do
    opts
    |> Keyword.get(:sources, default_sources())
    |> Enum.find_value(fn source -> app |> source.() |> validate() end)
  end

  @doc """
  Resolves baselines for many apps at once, returning `%{app_name => baseline}`.

  Each distinct app is resolved exactly once, and resolutions run concurrently —
  the Hex source shells out to `mix hex.info` per app, so a serial chain would
  make every bump pay the sum of those round-trips. A source that hangs past
  `:timeout` (default #{@default_timeout}ms) yields `nil` for that app rather
  than failing the bump.
  """
  def resolve_many(apps, opts \\ []) do
    uniq_apps = Enum.uniq_by(apps, & &1.name)

    uniq_apps
    |> Task.async_stream(
      fn app -> resolve(app, opts) end,
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(uniq_apps)
    |> Map.new(fn
      {{:ok, baseline}, app} -> {app.name, baseline}
      {{:exit, _reason}, app} -> {app.name, nil}
    end)
  end

  @doc """
  Returns the highest version among `tags` scoped to `app_name`, or `nil`.

  Tags are matched on the exact `<app_name>-v` prefix, so `ex_pdf` never picks up
  an `ex_pdf_components-v2.0.0` tag. Comparison is semantic, not lexicographic:
  `1.0.10` outranks `1.0.9`. Malformed tags are ignored.
  """
  def highest_version(tags, app_name) do
    prefix = "#{app_name}-v"

    tags
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> Enum.filter(&parseable?/1)
    |> Enum.sort({:desc, Elixir.Version})
    |> List.first()
  end

  defp default_sources, do: [&from_hex/1, &from_git_tag/1, &from_git_head/1]

  defp from_hex(app), do: HexStatus.published_version(app.name)

  defp from_git_tag(app), do: Git.tags() |> highest_version(app.name)

  defp from_git_head(app) do
    case Git.show("HEAD:#{Path.join(app.path, "mix.exs")}") do
      {:ok, content} -> Version.extract_from_source(content)
      :error -> nil
    end
  end

  defp validate(version) do
    if parseable?(version), do: version, else: nil
  end

  defp parseable?(version) when is_binary(version) do
    match?({:ok, _}, Elixir.Version.parse(version))
  end

  defp parseable?(_), do: false
end
