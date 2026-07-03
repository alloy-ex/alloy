defmodule Alloy.Tool.Inline do
  @moduledoc """
  A tool defined as data instead of a module.

  Module tools (`Alloy.Tool`) are the right shape for tools you own and
  test. Inline tools cover the cases modules can't: tools discovered at
  runtime (an MCP server's tool list, a database of user-defined actions)
  and one-off tools that don't warrant a file.

  Build one with `Alloy.Tool.inline/1`:

      weather =
        Alloy.Tool.inline(
          name: "get_weather",
          description: "Get current weather for a location",
          input_schema: %{
            type: "object",
            properties: %{location: %{type: "string"}},
            required: ["location"]
          },
          execute: fn %{"location" => loc}, _context ->
            {:ok, "22°C and clear in " <> loc}
          end
        )

      Alloy.run("What's the weather in Sydney?",
        provider: provider,
        tools: [weather, Alloy.Tool.Core.Read]
      )

  `tools:` accepts inline tools and tool modules interchangeably.

  ## Fields

  Required:

  - `:name` - unique tool name (string, used in API calls)
  - `:description` - what the tool does, for the model
  - `:input_schema` - JSON Schema map for the input
  - `:execute` - 2-arity function `(input, context)` returning
    `{:ok, text}`, `{:ok, text, structured_data}`, or `{:error, reason}` —
    the same contract as `c:Alloy.Tool.execute/2`

  Optional:

  - `:concurrent?` - safe to run in parallel with other tools
    (default `true`, matching module tools without a `concurrent?/0`)
  - `:max_result_chars` - cap on result text, or `:unlimited`
    (default `nil`, no cap)
  - `:allowed_callers` - as `c:Alloy.Tool.allowed_callers/0`
    (default `nil`, omitted from the tool definition)
  - `:result_type` - as `c:Alloy.Tool.result_type/0`
    (default `nil`, omitted from the tool definition)
  - `:strict` - request provider strict-mode schema enforcement
    (default `false`)
  - `:input_examples` - example input maps for providers that support them
    (default `[]`)
  - `:defer_loading` - request provider-side deferred tool loading
    (default `false`)
  """

  @enforce_keys [:name, :description, :input_schema, :execute]
  defstruct [
    :name,
    :description,
    :input_schema,
    :execute,
    :max_result_chars,
    :allowed_callers,
    :result_type,
    input_examples: [],
    strict: false,
    defer_loading: false,
    concurrent?: true
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input_schema: map(),
          execute: (map(), map() ->
                      {:ok, String.t()}
                      | {:ok, String.t(), map()}
                      | {:error, String.t()}),
          concurrent?: boolean(),
          max_result_chars: pos_integer() | :unlimited | nil,
          allowed_callers: [atom()] | nil,
          result_type: :text | :structured | nil,
          input_examples: [map()],
          strict: boolean(),
          defer_loading: boolean()
        }

  @doc false
  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = tool) do
    unless is_binary(tool.name) and tool.name != "" do
      raise ArgumentError,
            "inline tool :name must be a non-empty string. Got: #{inspect(tool.name)}"
    end

    unless is_binary(tool.description) do
      raise ArgumentError,
            "inline tool #{inspect(tool.name)} :description must be a string. " <>
              "Got: #{inspect(tool.description)}"
    end

    unless is_map(tool.input_schema) do
      raise ArgumentError,
            "inline tool #{inspect(tool.name)} :input_schema must be a map. " <>
              "Got: #{inspect(tool.input_schema)}"
    end

    unless is_function(tool.execute, 2) do
      raise ArgumentError,
            "inline tool #{inspect(tool.name)} :execute must be a 2-arity function " <>
              "(input, context). Got: #{inspect(tool.execute)}"
    end

    unless is_boolean(tool.strict) do
      raise ArgumentError,
            "inline tool #{inspect(tool.name)} :strict must be a boolean. " <>
              "Got: #{inspect(tool.strict)}"
    end

    unless is_list(tool.input_examples) and Enum.all?(tool.input_examples, &is_map/1) do
      raise ArgumentError,
            "inline tool #{inspect(tool.name)} :input_examples must be a list of maps. " <>
              "Got: #{inspect(tool.input_examples)}"
    end

    unless is_boolean(tool.defer_loading) do
      raise ArgumentError,
            "inline tool #{inspect(tool.name)} :defer_loading must be a boolean. " <>
              "Got: #{inspect(tool.defer_loading)}"
    end

    tool
  end
end
