defmodule Alloy.Result do
  @moduledoc """
  Structured result from an agent run.

  Returned by `Alloy.run/2` and `Alloy.stream/3`.
  Implements `Access` for bracket-syntax compatibility (`result[:text]`).

  ## Fields

    * `:text` — the text of the last assistant message (see `Alloy.Message.text/1`):
      `""` when that message has no text blocks (it only called tools, or the
      output was cut off), `nil` only when the conversation has no assistant message.
      With `:stop_after_tool`, this is the selected tool's final content instead;
      its metadata is in `metadata.final_tool`
    * `:output` — decoded JSON value when `:output_schema` is configured and
      the run completes normally, or `nil` otherwise
    * `:thinking` — the final assistant thinking/reasoning text (or `nil` if none),
      so callers need not dig it out of the last message's content blocks
    * `:messages` — full conversation history
    * `:usage` — accumulated `%Alloy.Usage{}` token counts
    * `:tool_calls` — list of tool execution metadata maps
    * `:metadata` — auxiliary result metadata such as provider-owned state
    * `:status` — final run status (`:completed`, `:max_turns`, `:error`, `:halted`)
    * `:stop_reason` — why the model stopped on the last provider response
      (`:end_turn`, `:tool_use`, `:max_tokens`, `:refusal`, `:pause_turn`), or
      `nil` if no response arrived. Check for `:max_tokens` to detect a
      truncated answer on a `:completed` run.
    * `:turns` — number of agent loop iterations
    * `:error` — error term (or `nil` on success)
    * `:request_id` — correlation ID for async requests (or `nil` for sync)
  """

  @behaviour Access

  alias Alloy.Agent.State
  alias Alloy.{Message, Usage}

  @type t :: %__MODULE__{
          text: String.t() | nil,
          output: term() | nil,
          thinking: String.t() | nil,
          messages: [Message.t()],
          usage: Usage.t(),
          tool_calls: [map()],
          metadata: map(),
          status: State.status(),
          stop_reason: Alloy.Provider.stop_reason() | nil,
          turns: non_neg_integer(),
          error: term() | nil,
          request_id: binary() | nil
        }

  defstruct [
    :text,
    :output,
    :thinking,
    :error,
    :request_id,
    :stop_reason,
    messages: [],
    usage: %Usage{},
    tool_calls: [],
    metadata: %{},
    status: :completed,
    turns: 0
  ]

  @doc """
  Build a `Result` from a final `State`.

  Extracts text, messages, usage, tool calls, status, turns, and error
  from the state. The `request_id` is left as `nil` — async callers
  overlay it via `%{result | request_id: id}`.
  """
  @spec from_state(State.t()) :: t()
  def from_state(%State{} = state) do
    %__MODULE__{
      text: final_text(state),
      output: final_output(state),
      thinking: State.last_assistant_thinking(state),
      messages: State.messages(state),
      usage: state.usage,
      tool_calls: state.tool_calls,
      metadata: build_metadata(state),
      status: state.status,
      stop_reason: state.stop_reason,
      turns: state.turn,
      error: state.error
    }
  end

  @doc """
  Tags a result the way `Alloy.run/2` returns it.

  `{:ok, result}` when the run completed or stopped at `:max_turns`;
  `{:error, result}` for every other status (`:error`, `:halted`).
  """
  @spec wrap(t()) :: {:ok, t()} | {:error, t()}
  def wrap(%__MODULE__{status: status} = result) when status in [:completed, :max_turns],
    do: {:ok, result}

  def wrap(%__MODULE__{} = result), do: {:error, result}

  # ── Access callbacks ─────────────────────────────────────────────────────

  @impl Access
  def fetch(result, key), do: Map.fetch(result, key)

  @impl Access
  def get_and_update(result, key, fun), do: Map.get_and_update(result, key, fun)

  @impl Access
  def pop(result, key) do
    value = Map.get(result, key)
    {value, Map.put(result, key, nil)}
  end

  defp build_metadata(%State{} = state) do
    %{}
    |> maybe_put_metadata(:provider_state, state.provider_state)
    |> maybe_put_metadata(:provider_response, state.provider_response_metadata)
    |> maybe_put_metadata(:run, Map.drop(state.run_metadata, [:final_tool, :output]))
    |> maybe_put_metadata(:final_tool, Map.get(state.run_metadata, :final_tool, %{}))
  end

  defp final_text(%State{status: :completed, run_metadata: %{final_tool: %{content: content}}}),
    do: content

  defp final_text(state), do: State.last_assistant_text(state)

  defp final_output(%State{status: :completed, run_metadata: %{output: output}}), do: output
  defp final_output(_state), do: nil

  defp maybe_put_metadata(metadata, _key, value) when is_map(value) and map_size(value) == 0,
    do: metadata

  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)
end
