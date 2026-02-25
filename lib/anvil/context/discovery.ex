defmodule Anvil.Context.Discovery do
  @moduledoc """
  Auto-discovers `.anvil/context/*.md` files and returns them as
  keyword sections suitable for `SystemPrompt.build/2`.

  Scans three tiers in order:
  1. Global: `~/.anvil/context/`
  2. Git root: `<git-root>/.anvil/context/`
  3. CWD: `<cwd>/.anvil/context/`

  Files are sorted alphabetically within each tier, and all tiers are
  concatenated (no dedup). Non-`.md` files are ignored.
  """

  @context_subdir ".anvil/context"

  @doc """
  Discovers context files and returns `[{filename_atom, content}]`.

  ## Options
    - `:home` — override the home directory (default: `System.user_home!/0`)
    - `:working_directory` — the current working directory (default: `"."`)
  """
  @spec discover(keyword()) :: keyword(String.t())
  def discover(opts \\ []) do
    home = Keyword.get(opts, :home, System.user_home!())
    cwd = Keyword.get(opts, :working_directory, ".") |> Path.expand()

    git_root = find_git_root(cwd)

    cwd_dir =
      if cwd != git_root, do: Path.join(cwd, @context_subdir)

    dirs =
      [
        Path.join(home, @context_subdir),
        git_root && Path.join(git_root, @context_subdir),
        cwd_dir
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.flat_map(dirs, &load_dir/1)
  end

  defp load_dir(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(fn filename ->
          key = filename |> Path.rootname() |> String.to_atom()
          content = File.read!(Path.join(dir, filename))
          {key, content}
        end)

      {:error, _} ->
        []
    end
  end

  defp find_git_root(dir) do
    cond do
      File.dir?(Path.join(dir, ".git")) ->
        dir

      dir == "/" ->
        nil

      true ->
        find_git_root(Path.dirname(dir))
    end
  end
end
