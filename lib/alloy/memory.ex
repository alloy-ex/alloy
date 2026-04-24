defmodule Alloy.Memory do
  @moduledoc """
  Behaviour for a memory store compatible with Anthropic's `memory_20250818`
  tool.

  Alloy's memory primitive mirrors Anthropic's client-side memory tool
  contract one-for-one: six commands operating on a `/memories` directory
  tree, where Anthropic defines the protocol (command vocabulary, return
  string formats, path validation rules) and the store owns the backing
  bytes. This matches the `BetaAbstractMemoryTool` split in the official
  Python SDK.

  ## Usage

      defmodule MyApp.Memory.Disk do
        @behaviour Alloy.Memory

        @impl true
        def view(store, path), do: # ...
        @impl true
        def create(store, path, file_text), do: # ...
        # ... etc
      end

      Alloy.run("Remember that the user prefers SI units",
        provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-sonnet-4-6"},
        memory: {MyApp.Memory.Disk, root: "/var/agent/memories"}
      )

  ## The store term

  The first argument to every callback is an opaque `store` term that
  Alloy passes through verbatim. Its contents are whatever the second
  element of the `{Module, opts}` tuple holds: a keyword list, a map, a
  `pid()`, a struct — the store module decides.

  Alloy intentionally does NOT bake session scoping into the contract:
  multi-session isolation is the store's job, not the protocol's. If
  you want per-session memory trees, pass `session_id: "..."` inside
  your store opts and let the store namespace internally.

  ## Path rules

  All paths must start with `/memories/` (no leading path traversal,
  no absolute filesystem paths leaking in). `Alloy.Memory.validate_path/1`
  enforces this before routing a call to the store — the store does
  not need to re-check.

  ## Provider support

  As of Alloy 0.12.0, only `Alloy.Provider.Anthropic` wires the
  `memory_20250818` tool. Configuring `:memory` with any other provider
  raises at `Alloy.run/2` entry. When other providers ship their own
  memory primitives, Alloy will route accordingly.

  ## References

  - [Anthropic memory tool docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)
  - [Context management announcement (2025-09-29)](https://claude.com/blog/context-management)
  - [Python SDK `BetaAbstractMemoryTool`](https://github.com/anthropics/anthropic-sdk-python/blob/main/examples/memory/basic.py)
  """

  @typedoc """
  Opaque store handle. Whatever the user puts in the `{Module, opts}`
  tuple's second element — Alloy treats it as an opaque term.
  """
  @type store :: term()

  @typedoc """
  A path rooted at `/memories/`. Enforced by `validate_path/1` before
  the callback is invoked.
  """
  @type path :: String.t()

  @typedoc """
  Every callback returns a text result (sent back to the model as the
  tool_result content) or an error. For `view` on a directory, the text
  result is the directory listing rendered however the store prefers
  (one path per line is conventional).
  """
  @type result :: {:ok, String.t()} | {:error, term()}

  @doc """
  Read a file or list a directory at `path`.

  For files, return the file content. For directories, return a
  directory listing the model can parse. Returning `{:error, :enoent}`
  is a valid answer for a path that has never been written.
  """
  @callback view(store(), path()) :: result()

  @doc """
  Create (or overwrite) `path` with `file_text`. Parent directories
  are created implicitly.
  """
  @callback create(store(), path(), file_text :: String.t()) :: result()

  @doc """
  Replace the first occurrence of `old_str` with `new_str` inside the
  file at `path`. The store should return an error if `old_str` is
  not found or if the match is non-unique — the model uses the error
  message to decide what to do next.
  """
  @callback str_replace(store(), path(), old_str :: String.t(), new_str :: String.t()) :: result()

  @doc """
  Insert `text` at 1-based line `insert_line` in the file at `path`.
  `insert_line == 0` inserts at the top of the file.
  """
  @callback insert(store(), path(), insert_line :: non_neg_integer(), text :: String.t()) ::
              result()

  @doc """
  Delete the file or directory at `path` (recursively for directories).
  """
  @callback delete(store(), path()) :: result()

  @doc """
  Rename `old_path` to `new_path`. Both paths must be under `/memories/`.
  """
  @callback rename(store(), old_path :: path(), new_path :: path()) :: result()

  @doc """
  Validate that `path` is rooted at `/memories/` and contains no
  upward traversal. Returns `{:ok, normalized}` or `{:error, reason}`.

  The returned path has any `./` segments collapsed and no trailing
  slash (except the root `/memories/`).
  """
  @spec validate_path(String.t()) :: {:ok, path()} | {:error, String.t()}
  def validate_path(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/memories") ->
        {:error, "path must start with /memories: #{inspect(path)}"}

      String.contains?(path, "/../") or String.ends_with?(path, "/..") ->
        {:error, "path must not contain upward traversal: #{inspect(path)}"}

      true ->
        {:ok, normalize(path)}
    end
  end

  def validate_path(other), do: {:error, "path must be a string, got: #{inspect(other)}"}

  defp normalize("/memories"), do: "/memories"
  defp normalize("/memories/"), do: "/memories"

  defp normalize(path) do
    path
    |> String.replace(~r{/+}, "/")
    |> String.replace_suffix("/", "")
  end
end
