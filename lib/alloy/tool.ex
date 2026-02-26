defmodule Alloy.Tool do
  @moduledoc """
  Behaviour for tools that agents can call.

  Tools always return strings - if a tool produces structured data,
  it should `Jason.encode!/1` it. This eliminates serialization bugs
  at the boundary between tools and the agent loop.

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
          {:ok, Jason.encode!(%{temp: 72, condition: "sunny", location: loc})}
        end
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

  Always returns `{:ok, string}` or `{:error, string}`.
  """
  @callback execute(input :: map(), context :: map()) ::
              {:ok, String.t()} | {:error, String.t()}

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
