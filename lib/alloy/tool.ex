defmodule Alloy.Tool do
  @moduledoc """
  Behaviour for tools that agents can call.

  ## Required Callbacks

  Every tool must implement `name/0`, `description/0`, `input_schema/0`,
  and `execute/2`.

  ## Optional Callbacks

  Tools may optionally implement:

  - `allowed_callers/0` — declares which callers may invoke this tool
    (`:human`, `:code_execution`). Defaults to `[:human]`.
  - `result_type/0` — declares whether the tool returns `:text` or
    `:structured` data. Defaults to `:text`.
  - `strict?/0` — requests provider strict-mode schema enforcement. Defaults
    to `false`.
  - `input_examples/0` — example inputs for providers that support advanced
    tool-use metadata. Defaults to `[]`.
  - `defer_loading?/0` — requests provider-side deferred loading where
    supported. Defaults to `false`.
  - `native_types/0` — a provider's built-in type for this tool, such as
    Anthropic's `memory_20250818`. Defaults to `%{}`.

  ## Structured Results

  Tools can return a 3-tuple `{:ok, text, data}` where `text` is the
  human-readable result and `data` is a map of structured data for
  programmatic consumption (e.g., by a code execution sandbox).

  ## Path Security

  Set `:allowed_paths` in the agent context to restrict file access:

      Alloy.run("Read the config",
        context: %{allowed_paths: ["/home/user/project"]},
        tools: [Alloy.Tool.Core.Read]
      )

  When configured, `resolve_path/2` follows symlinks and returns
  `{:error, reason}` for paths whose real location is outside the allowed
  directories. The built-in read, write and edit tools use it; it does
  not restrict the bash tool.

  ## Example

      defmodule MyApp.Tools.Weather do
        @behaviour Alloy.Tool

        @impl true
        def name, do: "get_weather"

        @impl true
        def description, do: "Get current weather for a location"

        @impl true
        def input_schema do
          %{
            type: "object",
            properties: %{location: %{type: "string", description: "City name"}},
            required: ["location"]
          }
        end

        @impl true
        def execute(%{"location" => loc}, _context) do
          {:ok, "72°F, sunny in \#{loc}", %{temp: 72, condition: "sunny", location: loc}}
        end

        @impl true
        def allowed_callers, do: [:human, :code_execution]

        @impl true
        def result_type, do: :structured
      end
  """

  @doc "Unique tool name (used in API calls)."
  @callback name() :: String.t()

  @doc "Human-readable description of what the tool does."
  @callback description() :: String.t()

  @doc "JSON Schema defining the tool's input parameters."
  @callback input_schema() :: map()

  @doc """
  Execute the tool with the given input.

  Context is a map that may contain:
  - `:working_directory` - base path for file operations
  - `:config` - agent config struct
  - `:allowed_paths` - list of allowed directory prefixes for file access
  - any custom keys added by middleware

  Returns `{:ok, string}` or `{:error, string}` for text-only results.
  Optionally returns `{:ok, string, map}` to include structured data
  alongside the text (for programmatic consumption by code execution).
  """
  @callback execute(input :: map(), context :: map()) ::
              {:ok, String.t()} | {:ok, String.t(), map()} | {:error, String.t()}

  @doc """
  Declares which callers may invoke this tool.

  - `:human` — the tool can be called by the model during normal conversation
  - `:code_execution` — the tool can be called from a code execution sandbox

  Defaults to `[:human]` when not implemented. Providers that support
  `allowed_callers` (e.g., Anthropic) include this in the tool definition
  sent to the API.
  """
  @callback allowed_callers() :: [:human | :code_execution]

  @doc """
  Declares the tool's result type.

  - `:text` — tool returns `{:ok, String.t()}` (the default)
  - `:structured` — tool returns `{:ok, String.t(), map()}`

  Used by the executor and downstream consumers to know whether
  structured data is available in the tool result metadata.
  """
  @callback result_type() :: :text | :structured

  @doc """
  Whether providers should use strict schema enforcement for this tool.

  Strict tools must declare `additionalProperties: false` on their top-level
  input schema. Alloy validates this instead of mutating the schema silently.
  """
  @callback strict?() :: boolean()

  @doc """
  Example tool inputs for provider tool-use guidance.
  """
  @callback input_examples() :: [map()]

  @doc """
  Whether providers that support deferred tool loading should defer this tool.
  """
  @callback defer_loading?() :: boolean()

  @doc """
  Maximum characters in the tool result before truncation.
  The executor truncates results exceeding this, keeping head + tail.
  Defaults to `:unlimited` when not implemented.
  """
  @callback max_result_chars() :: pos_integer() | :unlimited

  @doc """
  Whether this tool is safe to run concurrently with other tools.
  State-mutating tools (file write, bash) should return false.
  Defaults to `true` when not implemented.
  """
  @callback concurrent?() :: boolean()

  @doc """
  A provider's own schema for this tool, keyed by provider family.

  A provider that finds its key sends the tool as that built-in type
  instead of as a function with `input_schema`; every other provider uses
  `input_schema`. `Alloy.Provider.Anthropic` reads `:anthropic`, so
  `%{anthropic: "memory_20250818"}` makes Claude use its trained memory
  tool while other models see the JSON schema. The tool still runs on the
  client like any other. Defaults to `%{}`.
  """
  @callback native_types() :: %{optional(atom()) => String.t()}

  @optional_callbacks [
    allowed_callers: 0,
    result_type: 0,
    strict?: 0,
    input_examples: 0,
    defer_loading?: 0,
    max_result_chars: 0,
    concurrent?: 0,
    native_types: 0
  ]

  @doc """
  Build an inline tool — a tool defined as data instead of a module.

  Accepts the same information as the behaviour callbacks, as options.
  The returned `Alloy.Tool.Inline` struct can be passed in `tools:`
  alongside tool modules. Use this for tools discovered at runtime
  (e.g., an MCP server's tool list) or one-off tools that don't warrant
  a module:

      lookup =
        Alloy.Tool.inline(
          name: "lookup_user",
          description: "Look up a user by email",
          input_schema: %{
            type: "object",
            properties: %{email: %{type: "string"}},
            required: ["email"]
          },
          execute: fn %{"email" => email}, _context ->
            case MyApp.Accounts.get_by_email(email) do
              nil -> {:error, "No user with email " <> email}
              user -> {:ok, "User: " <> user.name}
            end
          end
        )

  See `Alloy.Tool.Inline` for all options. Raises `ArgumentError` on
  invalid definitions.
  """
  @spec inline(keyword() | map()) :: Alloy.Tool.Inline.t()
  def inline(fields) when is_list(fields) or is_map(fields) do
    alias Alloy.Tool.Inline

    fields = Map.new(fields)
    known = Inline.__struct__() |> Map.keys() |> List.delete(:__struct__)

    case Enum.find(Map.keys(fields), &(&1 not in known)) do
      nil -> Inline |> struct!(fields) |> Inline.validate!()
      key -> raise ArgumentError, "unknown inline tool option: #{inspect(key)}"
    end
  end

  @doc """
  Resolve a file path against the working directory from context.

  Absolute paths are expanded. Relative paths are joined with the
  `:working_directory` from context, or expanded from cwd if not set.

  When `:allowed_paths` is set in context, every symlink in the path is
  followed and the resulting real path must equal one of the allowed
  directories (themselves resolved the same way) or sit beneath it.
  `/proj` allows `/proj/lib/app.ex` but not `/proj-secrets/key.txt`.
  Components that do not exist yet (a file about to be written) are
  accepted as they are. The real path is returned, so the tool opens the
  file that was checked. Returns `{:error, reason}` for a path outside
  the allowed directories or one that cannot be resolved (a symlink
  loop).

  The check happens before the tool opens the file. It is a guard for an
  agent's file tools, not a sandbox: a process that can create symlinks
  under an allowed directory between the check and the open (for
  example the agent's own bash tool) can still race it.
  """
  @spec resolve_path(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(file_path, context) do
    expanded =
      case Map.get(context, :working_directory) do
        nil -> Path.expand(file_path)
        wd -> Path.expand(file_path, wd)
      end

    case Map.get(context, :allowed_paths) do
      nil -> {:ok, expanded}
      roots when is_list(roots) -> check_allowed(expanded, roots)
    end
  end

  defp check_allowed(expanded, roots) do
    with {:ok, real} <- real_path(expanded) do
      if Enum.any?(roots, &inside?(real, &1)) do
        {:ok, real}
      else
        {:error, "Path #{expanded} is outside allowed directories"}
      end
    end
  end

  defp inside?(real, root) do
    case real_path(Path.expand(root)) do
      {:ok, root} ->
        real == root or String.starts_with?(real, String.trim_trailing(root, "/") <> "/")

      {:error, _} ->
        false
    end
  end

  # Linux's MAXSYMLINKS; a path needing more hops is a loop.
  @max_symlink_hops 40

  # Walks the path one component at a time from its root, following
  # symlinks and applying ".." to the real directory reached so far (as
  # the kernel does), so the result names the file the OS would open.
  defp real_path(path) do
    [root | segments] = Path.split(path)

    case walk(segments, root, 0) do
      {:ok, real} -> {:ok, real}
      :loop -> {:error, "Path #{path} cannot be resolved: too many levels of symbolic links"}
    end
  end

  defp walk(_segments, _real, hops) when hops > @max_symlink_hops, do: :loop
  defp walk([], real, _hops), do: {:ok, real}
  defp walk(["." | rest], real, hops), do: walk(rest, real, hops)
  defp walk([".." | rest], real, hops), do: walk(rest, Path.dirname(real), hops)

  defp walk([segment | rest], real, hops) do
    candidate = Path.join(real, segment)

    case :file.read_link_all(candidate) do
      {:ok, target} -> follow(List.to_string(target), rest, real, hops + 1)
      {:error, _not_a_link_or_missing} -> walk(rest, candidate, hops)
    end
  end

  defp follow(target, rest, real, hops) do
    case {Path.type(target), Path.split(target)} do
      {:absolute, [root | segments]} -> walk(segments ++ rest, root, hops)
      {_relative, segments} -> walk(segments ++ rest, real, hops)
    end
  end
end
