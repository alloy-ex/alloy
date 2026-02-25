defmodule Anvil.Skill do
  @moduledoc """
  Reusable prompt templates discovered from `.anvil/skills/` directories.

  Skills are Markdown files with optional YAML-like frontmatter:

      ---
      name: code-review
      description: Review code for quality and security
      ---

      You are performing a code review. Focus on:
      - Security vulnerabilities
      - Performance issues

      Review the following: {{input}}

  ## Discovery

  Skills are loaded from two locations (project overrides global):
  1. Global: `~/.anvil/skills/`
  2. Project: `.anvil/skills/`

  ## Placeholders

  Use `{{input}}` for the main user input, or `{{name}}` for named
  placeholders replaced via a map.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          body: String.t(),
          path: String.t()
        }

  defstruct [:name, :description, :body, :path]

  @doc """
  Parses a skill from file content and its path.

  Extracts frontmatter (between `---` delimiters) for name/description.
  Falls back to filename (without extension) for the name.
  """
  @spec parse(String.t(), String.t()) :: t()
  def parse(content, path) do
    {frontmatter, body} = parse_frontmatter(content)
    filename_name = path |> Path.basename() |> Path.rootname()

    %__MODULE__{
      name: Map.get(frontmatter, "name", filename_name),
      description: Map.get(frontmatter, "description"),
      body: String.trim(body),
      path: path
    }
  end

  @doc """
  Replaces placeholders in the skill body.

  When given a string, replaces `{{input}}`. When given a map,
  replaces all `{{key}}` patterns with corresponding values.
  """
  @spec apply(t(), String.t() | map()) :: String.t()
  def apply(%__MODULE__{body: body}, input) when is_binary(input) do
    String.replace(body, "{{input}}", input)
  end

  def apply(%__MODULE__{body: body}, replacements) when is_map(replacements) do
    Enum.reduce(replacements, body, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", value)
    end)
  end

  @doc """
  Discovers skills from global and project directories.

  Project skills override global skills with the same filename.

  ## Options
    - `:home` — override the home directory (default: `System.user_home!/0`)
    - `:project` — project directory to search (default: `"."`)
  """
  @spec discover(keyword()) :: [t()]
  def discover(opts \\ []) do
    home = Keyword.get(opts, :home, System.user_home!())
    project = Keyword.get(opts, :project, ".")

    global_dir = Path.join(home, ".anvil/skills")
    project_dir = Path.join(project, ".anvil/skills")

    global_skills = load_dir(global_dir)
    project_skills = load_dir(project_dir)

    # Project skills override global by filename
    project_filenames = MapSet.new(project_skills, fn s -> Path.basename(s.path) end)

    global_kept =
      Enum.reject(global_skills, fn s ->
        MapSet.member?(project_filenames, Path.basename(s.path))
      end)

    Enum.sort_by(global_kept ++ project_skills, & &1.name)
  end

  defp load_dir(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(fn filename ->
          path = Path.join(dir, filename)
          content = File.read!(path)
          parse(content, path)
        end)

      {:error, _} ->
        []
    end
  end

  defp parse_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---\n(.*)\z/s, content) do
      [_, frontmatter_str, body] ->
        frontmatter =
          frontmatter_str
          |> String.split("\n")
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line, ":", parts: 2) do
              [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
              _ -> acc
            end
          end)

        {frontmatter, body}

      nil ->
        {%{}, content}
    end
  end
end
