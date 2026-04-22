defmodule Releaser.CommitValidator do
  @moduledoc """
  Validates commit messages against Conventional Commits + project-specific rules.

  Pure functions — no git, no filesystem. The Mix task wraps this module to
  read a COMMIT_EDITMSG file and produce CLI output.

  ## Rules applied

    * **Format**: `<type>(<scope>)?(!)?: <subject>`
    * **Type**: must be in `bump_rules` or `allowed_types` when `strict_types: true`
    * **Scope**: must be in `allowed_scopes` (auto-inferred from app names +
      aliases when not configured) when `strict_scopes: true`
    * **No scope**: rejected when `allow_no_scope: false`
    * **Subject length**: `max_subject_length`, default 100

  ## Return

    * `:ok` — valid
    * `{:error, reason}` — one of:
        * `:missing_header`
        * `:bad_format`
        * `{:unknown_type, type, allowed}`
        * `{:unknown_scope, scope, allowed}`
        * `:scope_required`
        * `{:subject_too_long, length, max}`
  """

  # Header: `type(scope)!: subject`
  # Scopes may contain letters, digits, dashes, underscores, or commas (multi-scope).
  @header_regex ~r/^(?<type>[a-z]+)(?:\((?<scope>[a-z0-9_,\-\s]+)\))?(?<bang>!)?:\s+(?<subject>.+)$/

  # Git adds comment lines starting with `#` in the editor; we strip them
  # before validation so users opening an editor don't trip the check on
  # template help text.
  @doc """
  Validates a raw commit message string.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def validate(raw, commits_config, opts \\ []) do
    apps = Keyword.get(opts, :apps, [])

    header = extract_header(raw)
    validation = Map.get(commits_config, :validation, %{})

    with :ok <- check_present(header),
         {:ok, parsed} <- check_format(header),
         :ok <- check_type(parsed, commits_config, validation),
         :ok <- check_scope(parsed, commits_config, validation, apps),
         :ok <- check_subject_length(parsed, validation),
         :ok <- check_body_separation(raw, header) do
      :ok
    end
  end

  @doc """
  Humanizes an error reason for display.
  """
  @spec format_error(term(), map(), [map()]) :: String.t()
  def format_error(reason, commits_config, apps) do
    case reason do
      :missing_header ->
        "Commit message is empty."

      :bad_format ->
        """
        Commit message does not match Conventional Commits format.

        Expected: <type>(<scope>)?(!)?: <subject>
        """

      {:unknown_type, type, allowed} ->
        """
        Unknown commit type "#{type}".

        Allowed types: #{Enum.join(allowed, ", ")}
        """

      {:unknown_scope, scope, allowed} ->
        """
        Unknown scope "#{scope}".

        Allowed scopes: #{Enum.join(allowed, ", ")}
        """

      :scope_required ->
        allowed = resolve_allowed_scopes(commits_config, apps)

        """
        A scope is required. Use one of: #{Enum.join(allowed, ", ")}
        """

      {:subject_too_long, n, max} ->
        "Subject is #{n} characters; maximum allowed is #{max}."

      :missing_body_separator ->
        """
        Per Conventional Commits v1.0.0, a blank line is required between
        the description and the body.
        """
    end
  end

  @doc """
  Returns the list of allowed scopes, resolving from config + apps.
  """
  @spec resolve_allowed_scopes(map(), [map()]) :: [String.t()]
  def resolve_allowed_scopes(commits_config, apps) do
    validation = Map.get(commits_config, :validation, %{})

    case Map.get(validation, :allowed_scopes) do
      nil -> auto_infer_scopes(commits_config, apps)
      list when is_list(list) -> list
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp extract_header(raw) do
    raw
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.find(&(String.trim(&1) != ""))
    |> case do
      nil -> ""
      line -> line
    end
  end

  defp check_present(""), do: {:error, :missing_header}
  defp check_present(_), do: :ok

  defp check_format(header) do
    case Regex.named_captures(@header_regex, header) do
      nil ->
        {:error, :bad_format}

      %{"type" => type, "scope" => scope, "bang" => bang, "subject" => subject} ->
        scope_val = if scope == "", do: nil, else: scope

        {:ok,
         %{
           type: type,
           scope: scope_val,
           breaking: bang == "!",
           subject: subject
         }}
    end
  end

  defp check_type(%{type: type}, commits_config, validation) do
    if Map.get(validation, :strict_types, false) do
      allowed = allowed_types(commits_config, validation)

      if type in allowed do
        :ok
      else
        {:error, {:unknown_type, type, allowed}}
      end
    else
      :ok
    end
  end

  defp check_scope(%{scope: nil}, _commits_config, validation, _apps) do
    if Map.get(validation, :allow_no_scope, true) do
      :ok
    else
      {:error, :scope_required}
    end
  end

  defp check_scope(%{scope: scope}, commits_config, validation, apps) do
    if Map.get(validation, :strict_scopes, false) do
      allowed = resolve_allowed_scopes(commits_config, apps)

      # Multi-scope: "feat(xml,csd)". Validate each one.
      scopes =
        scope
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      case Enum.find(scopes, &(&1 not in allowed)) do
        nil -> :ok
        bad -> {:error, {:unknown_scope, bad, allowed}}
      end
    else
      :ok
    end
  end

  defp check_subject_length(%{subject: subject}, validation) do
    max = Map.get(validation, :max_subject_length, 100)
    length = String.length(subject)

    if length <= max do
      :ok
    else
      {:error, {:subject_too_long, length, max}}
    end
  end

  # Per spec v1.0.0: "A commit body is free-form and MAY consist of any
  # number of newline separated paragraphs. A commit body MUST begin one
  # blank line after the description."
  #
  # We only enforce when a body exists — single-line commits are valid.
  defp check_body_separation(raw, header) do
    lines =
      raw
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing/1)
      |> Enum.reject(&String.starts_with?(&1, "#"))

    # Find the header index (first non-blank, non-comment line).
    header_idx = Enum.find_index(lines, &(String.trim(&1) == header))

    case header_idx do
      nil ->
        :ok

      idx ->
        rest = Enum.drop(lines, idx + 1)

        # If nothing after header or everything is blank → no body → ok.
        if Enum.all?(rest, &(String.trim(&1) == "")) do
          :ok
        else
          # First line after header must be blank.
          case rest do
            [first | _] when first == "" -> :ok
            _ -> {:error, :missing_body_separator}
          end
        end
    end
  end

  defp allowed_types(commits_config, validation) do
    bump_types = commits_config |> Map.get(:bump_rules, %{}) |> Map.keys()
    extra = Map.get(validation, :allowed_types, [])
    Enum.uniq(bump_types ++ extra)
  end

  defp auto_infer_scopes(commits_config, apps) do
    app_names = Enum.map(apps, & &1.name)
    aliases = commits_config |> Map.get(:scope_aliases, %{}) |> Map.keys()
    Enum.uniq(app_names ++ aliases)
  end
end
