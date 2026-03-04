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

  ## Structured Results

  Tools can return a 3-tuple `{:ok, text, data}` where `text` is the
  human-readable result and `data` is a map of structured data for
  programmatic consumption (e.g., by a code execution sandbox).

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

  @optional_callbacks [allowed_callers: 0, result_type: 0]

  @doc """
  Resolve a file path against the working directory from context.

  Absolute paths are returned as-is. Relative paths are joined with
  the `:working_directory` from context, or expanded from cwd if not set.
  """
  @spec resolve_path(String.t(), map()) :: String.t()
  def resolve_path(file_path, context) do
    if Path.type(file_path) == :absolute do
      file_path
    else
      case Map.get(context, :working_directory) do
        nil -> Path.expand(file_path)
        wd -> Path.join(wd, file_path)
      end
    end
  end
end
