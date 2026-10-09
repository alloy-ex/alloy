defmodule Alloy.Memory do
  @moduledoc """
  Behaviour for a memory store, and the memory tool that reads and writes
  it.

  The memory tool follows Anthropic's client-side `memory_20250818`
  contract: six commands operating on a `/memories` directory tree, where
  the contract defines the commands, results and path rules and the store
  owns the bytes. This matches the `BetaAbstractMemoryTool` split in the
  official Python SDK.

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
        provider: {Alloy.Provider.Anthropic, api_key: key, model: "claude-sonnet-5-5"},
        tools: [Alloy.Memory.tool({MyApp.Memory.Disk, root: "/var/agent/memories"})]
      )

  `memory: {MyApp.Memory.Disk, opts}` is shorthand for adding that tool.
  The memory tool is an ordinary tool: it runs through the tool executor,
  so `:before_tool_call` middleware, tool events and `:tool_timeout`
  apply to it, and its calls run one at a time in the order the model
  made them.

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

  All paths must be `/memories` or start with `/memories/`, with no `..`
  segment and no `%`, `\\` or NUL byte. `Alloy.Memory.validate_path/1`
  enforces this before routing a call to the store, so the store does
  not need to re-check. The router also refuses to `delete` or `rename`
  the `/memories` root itself, applies `view_range` to the text `view/2`
  returns, and passes `""` as `new_str` when the model omits it (which
  deletes `old_str`), as the memory tool contract specifies.

  ## Provider support

  Every provider can use the memory tool. `Alloy.Provider.Anthropic` sends
  it as Anthropic's built-in `memory_20250818` type, which Claude is
  trained on; other providers receive it as a function tool with a JSON
  schema for the same six commands.

  ## References

  - [Anthropic memory tool docs](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool)
  - [Context management announcement (2025-09-29)](https://claude.com/blog/context-management)
  - [Python SDK `BetaAbstractMemoryTool`](https://github.com/anthropics/anthropic-sdk-python/blob/main/examples/memory/basic.py)
  """

  alias Alloy.Memory.Router

  @tool_name "memory"
  @tool_type "memory_20250818"

  @tool_description """
  Persistent memory that outlives this conversation, stored as files \
  under /memories. View /memories before starting a task, and record \
  progress and lessons there as you work. Commands: view (read a file or \
  list a directory; optional view_range [start_line, end_line], -1 for \
  the end), create (path, file_text), str_replace (path, old_str, \
  new_str), insert (path, insert_line, insert_text; line 0 is the top), \
  delete (path) and rename (old_path, new_path).\
  """

  @tool_schema %{
    "type" => "object",
    "properties" => %{
      "command" => %{
        "type" => "string",
        "enum" => ["view", "create", "str_replace", "insert", "delete", "rename"]
      },
      "path" => %{"type" => "string", "description" => "A path under /memories"},
      "view_range" => %{"type" => "array", "items" => %{"type" => "integer"}},
      "file_text" => %{"type" => "string"},
      "old_str" => %{"type" => "string"},
      "new_str" => %{"type" => "string"},
      "insert_line" => %{"type" => "integer"},
      "insert_text" => %{"type" => "string"},
      "old_path" => %{"type" => "string"},
      "new_path" => %{"type" => "string"}
    },
    "required" => ["command"]
  }

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
  message to decide what to do next. `new_str` is `""` when the model
  omits it, which deletes `old_str`.
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
  The memory tool for a `{store_module, store}` binding, ready for `:tools`.

  The tool is named `"memory"` and runs its commands one at a time, in the
  order the model made them, so a `create` followed by a `str_replace` on
  the same file behaves as written.

      tools: [Alloy.Memory.tool({MyApp.Memory.Disk, root: "/var/agent/memories"})]
  """
  @spec tool({module(), store()}) :: Alloy.Tool.Inline.t()
  def tool({module, _store} = binding) when is_atom(module) do
    Alloy.Tool.inline(
      name: @tool_name,
      description: @tool_description,
      input_schema: @tool_schema,
      execute: fn input, _context -> Router.dispatch(binding, input) end,
      concurrent?: false,
      native_types: %{anthropic: @tool_type}
    )
  end

  def tool(other) do
    raise ArgumentError,
          "Alloy.Memory.tool/1 expects a {module, store} tuple where module " <>
            "implements Alloy.Memory. Got: #{inspect(other)}"
  end

  @doc """
  Validate that `path` is `/memories` or lies under `/memories/` and
  contains no traversal. Returns `{:ok, normalized}` or
  `{:error, reason}`.

  Rejected: paths that merely share the prefix (`/memories_evil/x`,
  `/memories..`), any `..` segment, and any `%`, `\\` or NUL byte, which
  rules out URL-encoded (`%2e%2e%2f`) and Windows-style (`..\\`)
  traversal before a store decodes or maps the path.

  The returned path has repeated slashes and `.` segments collapsed and
  no trailing slash, so the root is always `/memories`.
  """
  @spec validate_path(String.t()) :: {:ok, path()} | {:error, String.t()}
  def validate_path(path) when is_binary(path) do
    segments = String.split(path, "/")

    cond do
      path != "/memories" and not String.starts_with?(path, "/memories/") ->
        {:error, "path must start with /memories/ (or be /memories): #{inspect(path)}"}

      String.contains?(path, ["%", "\\", <<0>>]) ->
        {:error, "path must not contain %, \\ or NUL bytes: #{inspect(path)}"}

      ".." in segments ->
        {:error, "path must not contain upward traversal: #{inspect(path)}"}

      true ->
        {:ok, "/" <> Enum.join(Enum.reject(segments, &(&1 in ["", "."])), "/")}
    end
  end

  def validate_path(other), do: {:error, "path must be a string, got: #{inspect(other)}"}
end
