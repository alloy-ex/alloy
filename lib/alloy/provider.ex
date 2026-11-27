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

  alias Alloy.Internal.Sanitize
  alias Alloy.Provider.Error

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

  @typedoc """
  Static API key string or 0-arity callback invoked per HTTP request attempt.
  """
  @type api_key :: String.t() | (-> String.t() | {:ok, String.t()} | {:error, term()})

  @typedoc """
  Portable reasoning effort level.
  """
  @type reasoning_effort :: :off | :low | :medium | :high | :xhigh

  @typedoc """
  Portable reasoning visibility hint (`:summarized` requests visible reasoning
  summaries where supported; `:omitted` suppresses them where supported).
  """
  @type reasoning_display :: :summarized | :omitted

  @typedoc """
  Portable reasoning configuration accepted at the top level of `Alloy.run/2` /
  `Alloy.stream/3` or inside a provider config map.
  """
  @type reasoning ::
          nil
          | reasoning_effort()
          | %{
              required(:effort) => reasoning_effort(),
              optional(:display) => reasoning_display() | nil
            }

  @typedoc """
  Canonical normalized reasoning configuration passed to providers.
  """
  @type normalized_reasoning :: %{
          effort: reasoning_effort(),
          display: reasoning_display() | nil
        }

  @reasoning_efforts [:off, :low, :medium, :high, :xhigh]
  @reasoning_displays [nil, :summarized, :omitted]

  @doc """
  Send messages to the provider and get a completion response.

  ## Parameters
  - `messages` - Conversation history as normalized `Alloy.Message` structs
  - `tool_defs` - Tool definitions (JSON Schema format)
  - `config` - Provider-specific configuration (API keys, model, etc.). When
    called from `Alloy.Agent.Turn`, Alloy may also inject `:system_prompt`,
    `:provider_state`, `:on_event` (when streaming), `:req_options` (with
    `:receive_timeout`), `:alloy_request_deadline` (monotonic ms deadline
    that built-in providers enforce as a hard wall-clock bound),
    `:alloy_cancel_token` (an `Alloy.Cancel.t()` token, injected only when
    the caller sets `:cancel_token`),
    `:reasoning` (a normalized `%{effort: ..., display: ...}` map, injected
    when top-level `:reasoning` is set), and
    `:output_schema` (an `Alloy.OutputSchema.t()` struct, injected only when
    the caller sets `:output_schema`). Custom providers using strict config
    validation should tolerate or ignore these runtime keys, and custom
    providers that want to support `:output_schema` should translate
    `config.output_schema.schema` (otherwise Alloy's final JSON decode will
    fail terminally unless the model already replied with conforming JSON).

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
  def stringify_keys(map) when is_map(map) and not is_struct(map) do
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

  Returns `{:ok, decoded_map}`, `{:error, %Alloy.Provider.Error{kind: :protocol_error}}`
  for valid non-object JSON, or `{:error, %Alloy.Provider.Error{kind: :malformed_reply}}`
  when JSON decoding fails.
  """
  @spec decode_body(binary() | map()) :: {:ok, map()} | {:error, Error.t()}
  def decode_body(body) when is_map(body), do: {:ok, body}

  def decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _non_map} ->
        {:error, %Error{kind: :protocol_error, message: "Expected JSON object response body"}}

      {:error, _} ->
        {:error, %Error{kind: :malformed_reply, message: "Failed to decode response JSON"}}
    end
  end

  @doc """
  Normalizes a portable `:reasoning` option into `nil` or
  `%{effort: effort, display: display}`.

  Returns `{:ok, normalized}` or `{:error, %Alloy.Provider.Error{kind: :invalid_request}}`.
  """
  @spec normalize_reasoning(term()) :: {:ok, normalized_reasoning() | nil} | {:error, Error.t()}
  def normalize_reasoning(nil), do: {:ok, nil}

  def normalize_reasoning(effort) when effort in @reasoning_efforts do
    {:ok, %{effort: effort, display: nil}}
  end

  def normalize_reasoning(map) when is_map(map) and not is_struct(map) do
    unknown = Map.keys(map) -- [:effort, :display]

    cond do
      unknown != [] ->
        invalid_reasoning(
          "Invalid :reasoning keys #{Sanitize.inspect_bounded(unknown)}; expected :effort and optional :display"
        )

      not Map.has_key?(map, :effort) ->
        invalid_reasoning("Invalid :reasoning map: missing required :effort key")

      map.effort not in @reasoning_efforts ->
        invalid_reasoning(
          "Invalid :reasoning :effort: expected one of #{inspect(@reasoning_efforts)}, got #{Sanitize.inspect_bounded(map.effort)}"
        )

      Map.get(map, :display) not in @reasoning_displays ->
        invalid_reasoning(
          "Invalid :reasoning :display: expected :summarized, :omitted, or nil, got #{Sanitize.inspect_bounded(Map.get(map, :display))}"
        )

      true ->
        display = if map.effort == :off, do: nil, else: Map.get(map, :display)
        {:ok, %{effort: map.effort, display: display}}
    end
  end

  def normalize_reasoning(other) do
    invalid_reasoning(
      "Invalid :reasoning: expected nil, one of #{inspect(@reasoning_efforts)}, or %{effort: ..., display?: ...}, got #{Sanitize.inspect_bounded(other)}"
    )
  end

  @doc """
  Like `normalize_reasoning/1`, raising `ArgumentError` on invalid input.
  """
  @spec normalize_reasoning!(term()) :: normalized_reasoning() | nil
  def normalize_reasoning!(value) do
    case normalize_reasoning(value) do
      {:ok, normalized} -> normalized
      {:error, %Error{message: msg}} -> raise ArgumentError, msg
    end
  end

  defp invalid_reasoning(message), do: {:error, %Error{kind: :invalid_request, message: message}}
end
