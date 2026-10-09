defmodule Alloy.Provider do
  @moduledoc """
  Behaviour for LLM providers.

  Each provider translates between its native wire format and Alloy's
  normalized `Alloy.Message` structs. The agent loop only sees normalized
  messages - adding a new provider means implementing this behaviour.

  ## Completion Response

  Providers return a map with:
  - `:stop_reason` - why the model stopped (see `t:stop_reason/0`)
  - `:messages` - list of `Alloy.Message` structs from the response
  - `:usage` - map with `:input_tokens` and `:output_tokens`
  - `:provider_state` - optional opaque map Alloy feeds back to the same provider
    on subsequent turns (for example, stored response IDs)
  - `:response_metadata` - optional provider response metadata exposed to the app
    layer (for example, citations or server-side tool usage)
  """

  @typedoc """
  Why the model stopped. Map the wire value to the closest of:

  - `:tool_use` - the model called client tools; Alloy runs them and loops
  - `:end_turn` - the model finished (also stop sequences)
  - `:max_tokens` - output hit the token limit (Anthropic `max_tokens` or
    `model_context_window_exceeded`, OpenAI `incomplete`/`length`, Gemini
    `MAX_TOKENS`). A truncated answer still completes, with the reason on
    `Alloy.Result`; a truncated tool call fails the run because it cannot
    be executed.
  - `:refusal` - a safety system stopped the output. Alloy discards the
    partial output and fails the run. Put the API's own details, with the
    string keys it sends, in `:response_metadata` under `:stop_details`.
  - `:pause_turn` - the provider paused a long server-side tool loop; Alloy
    sends the conversation back unchanged so it can continue.
  """
  @type stop_reason :: :tool_use | :end_turn | :max_tokens | :refusal | :pause_turn
  @type tool_def :: %{name: String.t(), description: String.t(), input_schema: map()}

  @type completion_response :: %{
          required(:stop_reason) => stop_reason(),
          required(:messages) => [Alloy.Message.t()],
          required(:usage) => map(),
          optional(:provider_state) => map(),
          optional(:response_metadata) => map()
        }

  @doc """
  Send messages to the provider and get a completion response.

  ## Parameters
  - `messages` - Conversation history as normalized `Alloy.Message` structs
  - `tool_defs` - Tool definitions (JSON Schema format)
  - `config` - Provider-specific configuration (API keys, model, etc.)

  ## Returns
  - `{:ok, completion_response()}` on success
  - `{:error, term()}` on failure
  """
  @callback complete(
              messages :: [Alloy.Message.t()],
              tool_defs :: [tool_def()],
              config :: map()
            ) :: {:ok, completion_response()} | {:error, term()}

  @doc """
  Stream a completion, calling `on_chunk` for each text delta.

  Returns the same `{:ok, completion_response()}` as `complete/3` once
  the stream finishes -- the full accumulated response.
  """
  @callback stream(
              messages :: [Alloy.Message.t()],
              tool_defs :: [tool_def()],
              config :: map(),
              on_chunk :: (String.t() -> :ok)
            ) :: {:ok, completion_response()} | {:error, term()}

  @optional_callbacks [stream: 4]

  # ── Shared Helpers (used by provider implementations) ──────────────

  @doc """
  Recursively convert atom keys to strings in maps.

  Used by providers to prepare JSON-compatible request bodies.
  """
  @spec stringify_keys(term()) :: term()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) ->
        {Atom.to_string(k), stringify_keys(v)}

      {k, v} when is_binary(k) ->
        {k, stringify_keys(v)}

      {k, _v} ->
        raise ArgumentError, "stringify_keys expects atom or string keys, got: #{inspect(k)}"
    end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value

  @doc """
  Decode a JSON binary response body, passing through maps unchanged.

  Returns `{:ok, decoded_map}` or `{:error, reason}`.
  """
  @spec decode_body(binary() | map()) :: {:ok, map()} | {:error, String.t()}
  def decode_body(body) when is_map(body), do: {:ok, body}

  def decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, "Failed to decode response JSON"}
    end
  end
end
