defmodule Alloy.Provider.ClaudeCode.StreamJson do
  @moduledoc false

  # Reads `claude -p --output-format stream-json` as it arrives, for two things.
  #
  # The reply text. With `--json-schema` the answer is not text: the model calls
  # Claude Code's StructuredOutput tool, and what streams is `input_json_delta`
  # fragments of `{"stop_reason": ..., "text": "...", "tool_calls": [...]}`. The
  # growing `text` value inside that partial JSON is decoded again per fragment
  # and only what is new goes to `on_chunk`. Only the StructuredOutput block's
  # input is read that way; any other tool's input is not the reply.
  #
  # Tools called natively. `claude -p` runs its own agent loop, and the model
  # sometimes calls a tool directly instead of naming it in `tool_calls` —
  # measured on a fresh session carrying a long transcript full of tool calls.
  # With `--tools ""` the CLI answers `No such tool available: <name>` to the
  # model, inside the same invocation, and the model concludes its tools are
  # gone: one agent made 27 refusals and 0 real calls, every one a `--resume` of
  # the session that first saw the refusals. So a native call is noticed the
  # moment its assistant message arrives: one naming a tool Alloy has is `call`,
  # to be run by Alloy instead; any other makes the session `stray`.
  #
  # Re-scanning the whole input per fragment is quadratic, and fine: it is one
  # reply, a few kilobytes.

  defstruct [
    :on_chunk,
    known: MapSet.new(),
    line: "",
    json: "",
    streamed: "",
    in_structured?: false,
    call: nil,
    stray?: false
  ]

  @type t :: %__MODULE__{
          on_chunk: (String.t() -> any()) | nil,
          known: MapSet.t(String.t()),
          line: binary(),
          json: binary(),
          streamed: String.t(),
          in_structured?: boolean(),
          call: map() | nil,
          stray?: boolean()
        }

  @structured "StructuredOutput"

  @doc false
  # `known` is the names of the tools Alloy offered this turn.
  @spec new((String.t() -> any()) | nil, [String.t()]) :: t()
  def new(on_chunk, known) when is_nil(on_chunk) or is_function(on_chunk, 1),
    do: %__MODULE__{on_chunk: on_chunk, known: MapSet.new(known)}

  @doc false
  # Raw stdout, in whatever pieces the port delivers; lines can straddle them.
  @spec feed(t(), binary()) :: t()
  def feed(%__MODULE__{} = state, data) do
    [partial | complete] = (state.line <> data) |> String.split("\n") |> Enum.reverse()

    complete
    |> Enum.reverse()
    |> Enum.reduce(%{state | line: partial}, &handle_line/2)
  end

  defp handle_line(_line, %__MODULE__{call: call} = state) when call != nil, do: state

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok,
       %{
         "type" => "stream_event",
         "event" => %{"type" => "content_block_start", "content_block" => block}
       }} ->
        %{state | json: "", in_structured?: match?(%{"name" => @structured}, block)}

      {:ok,
       %{
         "type" => "stream_event",
         "event" => %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "input_json_delta", "partial_json" => fragment}
         }
       }}
      when is_binary(fragment) ->
        if state.in_structured?, do: emit(%{state | json: state.json <> fragment}), else: state

      {:ok, %{"type" => "assistant", "message" => %{"content" => blocks}}} when is_list(blocks) ->
        Enum.reduce(blocks, state, &native_call/2)

      _ ->
        state
    end
  end

  defp native_call(%{"type" => "tool_use", "name" => @structured}, state), do: state

  defp native_call(%{"type" => "tool_use", "name" => name} = block, %{call: nil} = state)
       when is_binary(name) do
    if MapSet.member?(state.known, name) do
      %{state | call: %{id: block["id"], name: name, input: block["input"] || %{}}}
    else
      %{state | stray?: true}
    end
  end

  defp native_call(_block, state), do: state

  defp emit(%{on_chunk: nil} = state), do: state

  defp emit(state) do
    with text when is_binary(text) <- text_prefix(state.json),
         true <- byte_size(text) > byte_size(state.streamed),
         true <- String.starts_with?(text, state.streamed) do
      state.on_chunk.(
        binary_part(text, byte_size(state.streamed), byte_size(text) - byte_size(state.streamed))
      )

      %{state | streamed: text}
    else
      _ -> state
    end
  end

  @doc false
  # The decoded prefix of the top-level `"text"` string in a partial JSON
  # object, or nil before it starts.
  @spec text_prefix(binary()) :: String.t() | nil
  def text_prefix(json) do
    case walk(json, 0, nil, :key) do
      {:ok, raw} -> decode(raw)
      :none -> nil
    end
  end

  # Depth 1 is the payload object: a string there is a key until a `:` makes
  # the next one its value, and a `,` goes back to keys. Nested strings (tool
  # call arguments may well have a "text" key) are skipped whole.
  defp walk(<<>>, _depth, _key, _mode), do: :none
  defp walk(<<?", rest::binary>>, 1, "text", :value), do: {:ok, raw_prefix(rest, <<>>)}

  defp walk(<<?", rest::binary>>, depth, key, mode) do
    case read_string(rest, <<>>) do
      :eof ->
        :none

      {raw, rest} ->
        key = if depth == 1 and mode == :key, do: raw, else: key
        walk(rest, depth, key, mode)
    end
  end

  defp walk(<<?:, rest::binary>>, 1, key, :key), do: walk(rest, 1, key, :value)
  defp walk(<<?,, rest::binary>>, 1, _key, _mode), do: walk(rest, 1, nil, :key)

  defp walk(<<c, rest::binary>>, depth, key, mode) when c in [?{, ?[],
    do: walk(rest, depth + 1, key, mode)

  defp walk(<<c, rest::binary>>, depth, key, mode) when c in [?}, ?]],
    do: walk(rest, depth - 1, key, mode)

  defp walk(<<_c, rest::binary>>, depth, key, mode), do: walk(rest, depth, key, mode)

  defp read_string(<<?\\, c, rest::binary>>, acc), do: read_string(rest, <<acc::binary, ?\\, c>>)
  defp read_string(<<?", rest::binary>>, acc), do: {acc, rest}
  defp read_string(<<c, rest::binary>>, acc), do: read_string(rest, <<acc::binary, c>>)
  defp read_string(_eof, _acc), do: :eof

  # The string's raw content so far, cut before an escape that has not finished
  # arriving.
  defp raw_prefix(<<?\\, c, rest::binary>>, acc), do: raw_prefix(rest, <<acc::binary, ?\\, c>>)
  defp raw_prefix(<<?", _rest::binary>>, acc), do: acc
  defp raw_prefix(<<?\\>>, acc), do: acc
  defp raw_prefix(<<c, rest::binary>>, acc), do: raw_prefix(rest, <<acc::binary, c>>)
  defp raw_prefix(<<>>, acc), do: acc

  # A `\uXXXX` still arriving, or the high half of a surrogate pair whose low
  # half has not, is held back until it can decode.
  defp decode(raw) do
    raw = Regex.replace(~r/\\u[0-9a-fA-F]{0,3}$/, raw, "")

    case Jason.decode(~s(") <> raw <> ~s(")) do
      {:ok, text} ->
        text

      {:error, _} ->
        case Jason.decode(~s(") <> Regex.replace(~r/\\u[0-9a-fA-F]{4}$/, raw, "") <> ~s(")) do
          {:ok, text} -> text
          {:error, _} -> nil
        end
    end
  end
end
