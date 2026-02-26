defmodule Anvil.Provider do
  @moduledoc """
  Behaviour for LLM providers.

  Each provider translates between its native wire format and Anvil's
  normalized `Anvil.Message` structs. The agent loop only sees normalized
  messages - adding a new provider means implementing this behaviour.

  ## Completion Response

  Providers return a map with:
  - `:stop_reason` - `:tool_use` (continue looping) or `:end_turn` (done)
  - `:messages` - list of `Anvil.Message` structs from the response
  - `:usage` - map with `:input_tokens` and `:output_tokens`
  """

  @type stop_reason :: :tool_use | :end_turn
  @type tool_def :: %{name: String.t(), description: String.t(), input_schema: map()}

  @type completion_response :: %{
          stop_reason: stop_reason(),
          messages: [Anvil.Message.t()],
          usage: map()
        }

  @doc """
  Send messages to the provider and get a completion response.

  ## Parameters
  - `messages` - Conversation history as normalized `Anvil.Message` structs
  - `tool_defs` - Tool definitions (JSON Schema format)
  - `config` - Provider-specific configuration (API keys, model, etc.)

  ## Returns
  - `{:ok, completion_response()}` on success
  - `{:error, term()}` on failure
  """
  @callback complete(
              messages :: [Anvil.Message.t()],
              tool_defs :: [tool_def()],
              config :: map()
            ) :: {:ok, completion_response()} | {:error, term()}

  @doc """
  Stream a completion, calling `on_chunk` for each text delta.

  Returns the same `{:ok, completion_response()}` as `complete/3` once
  the stream finishes -- the full accumulated response.
  """
  @callback stream(
              messages :: [Anvil.Message.t()],
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
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
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
