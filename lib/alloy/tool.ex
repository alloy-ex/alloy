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

  When configured, `resolve_path/2` returns `{:error, reason}` for
  paths outside the allowed directories.

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

  @optional_callbacks [
    allowed_callers: 0,
    result_type: 0,
    strict?: 0,
    input_examples: 0,
    defer_loading?: 0,
    max_result_chars: 0,
    concurrent?: 0
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

  Absolute paths are returned as-is. Relative paths are joined with
  the `:working_directory` from context, or expanded from cwd if not set.

  When `:allowed_paths` is set in context, validates the resolved path
  falls within one of the allowed directories. Returns `{:error, reason}`
  if the path is outside the allowed directories.
  """
  @spec resolve_path(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_path(file_path, context) do
    resolved =
      if Path.type(file_path) == :absolute do
        Path.expand(file_path)
      else
        case Map.get(context, :working_directory) do
          nil -> Path.expand(file_path)
          wd -> Path.expand(Path.join(wd, file_path))
        end
      end

    case Map.get(context, :allowed_paths) do
      nil ->
        {:ok, resolved}

      paths when is_list(paths) ->
        # Resolve symlinks to prevent escaping allowed directories via symlink traversal.
        # Falls back to the expanded path for non-existent targets.
        real = resolve_real_path(resolved)

        if Enum.any?(paths, fn allowed ->
             String.starts_with?(real, resolve_real_path(Path.expand(allowed)))
           end) do
          {:ok, resolved}
        else
          {:error, "Path #{resolved} is outside allowed directories"}
        end
    end
  end

  defp resolve_real_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} ->
        target
        |> List.to_string()
        |> Path.expand(Path.dirname(path))
        |> resolve_real_path()

      {:error, _} ->
        # Not a symlink — check if a parent component is
        parent = Path.dirname(path)

        if parent == path do
          path
        else
          Path.join(resolve_real_path(parent), Path.basename(path))
        end
    end
  end
end
