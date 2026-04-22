defmodule Releaser.BumpArgs do
  @moduledoc false
  # Pure argument parsing and validation for `mix releaser.bump`.
  #
  # Kept in its own module so the logic is testable without touching
  # Mix.Task or the filesystem. Treat as internal API.

  @bump_types ~w[major minor patch]

  @doc """
  Validates `--mode` / `--tag` combinations.

  Returns `:ok` when valid, `{:error, reason}` otherwise.
  """
  def validate_opts(opts) do
    mode = Keyword.get(opts, :mode)
    tag = Keyword.get(opts, :tag)

    cond do
      mode not in [nil, "prerelease"] ->
        {:error, {:unknown_mode, mode}}

      mode == "prerelease" and is_nil(tag) ->
        {:error, :prerelease_requires_tag}

      true ->
        :ok
    end
  end

  @doc """
  Resolves raw positional args + discovered apps into a typed command.

  Returns one of:

    * `{:ok, {:bump, app, bump_type}}` — standard bump
    * `{:ok, {:release, app}}` — finalize pre-release
    * `{:ok, {:explicit, app, version_string}}` — explicit version
    * `{:ok, {:prerelease_only, app}}` — `--mode prerelease --tag X` without bump type
    * `{:error, :ambiguous_app}` — multi-app without name
    * `{:error, {:app_not_found, name}}` — name does not match any app
    * `{:error, :usage}` — malformed arguments
  """
  def resolve_command(positional, apps, opts) do
    case split_app(positional, apps) do
      {:error, reason} ->
        {:error, reason}

      {name, rest} when is_binary(name) ->
        if Enum.any?(apps, &(&1.name == name)) do
          dispatch(name, rest, opts)
        else
          {:error, {:app_not_found, name}}
        end
    end
  end

  # --- split_app -----------------------------------------------------------

  defp split_app([], apps) do
    case apps do
      [only] -> {only.name, []}
      _ -> {:error, :ambiguous_app}
    end
  end

  defp split_app([first | rest] = all, apps) do
    cond do
      Enum.any?(apps, &(&1.name == first)) ->
        {first, rest}

      first in @bump_types or first == "release" ->
        infer_single_app(all, apps)

      explicit_version?(first) ->
        infer_single_app(all, apps)

      true ->
        # Unknown first token — fall through so caller returns :app_not_found
        {first, rest}
    end
  end

  defp infer_single_app(positional, [only]), do: {only.name, positional}
  defp infer_single_app(_positional, _apps), do: {:error, :ambiguous_app}

  # --- dispatch ------------------------------------------------------------

  defp dispatch(app, [], opts) do
    case Keyword.get(opts, :mode) do
      "prerelease" -> {:ok, {:prerelease_only, app}}
      _ -> {:error, :usage}
    end
  end

  defp dispatch(app, ["release"], _opts), do: {:ok, {:release, app}}

  defp dispatch(app, [bump_type], _opts) when bump_type in @bump_types do
    {:ok, {:bump, app, String.to_atom(bump_type)}}
  end

  defp dispatch(app, [version_string], _opts) do
    if explicit_version?(version_string) do
      {:ok, {:explicit, app, version_string}}
    else
      {:error, :usage}
    end
  end

  defp dispatch(_app, _rest, _opts), do: {:error, :usage}

  defp explicit_version?(token) do
    case Elixir.Version.parse(token) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
