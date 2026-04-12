defmodule Alloy do
  @moduledoc """
  Model-agnostic agent harness for Elixir.

  Alloy provides the minimal agent loop: send messages to any LLM,
  execute tool calls, loop until done. Zero framework dependencies.

  ## Quick Start

      {:ok, result} = Alloy.run("What is 2+2?",
        provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-..."},
        system_prompt: "You are helpful."
      )
      result.text #=> "4"

  ## With Tools

      {:ok, result} = Alloy.run("Read mix.exs and tell me the version",
        provider: {Alloy.Provider.Anthropic, api_key: "sk-ant-..."},
        tools: [Alloy.Tool.Core.Read],
        max_turns: 10
      )

  ## Continuing a Conversation

      {:ok, result} = Alloy.run("Now edit that file",
        provider: {Alloy.Provider.OpenAI, api_key: "sk-..."},
        tools: [Alloy.Tool.Core.Read, Alloy.Tool.Core.Edit],
        messages: previous_result.messages
      )

  ## One-Shot Streaming

      {:ok, result} = Alloy.stream("Explain OTP", fn chunk ->
        IO.write(chunk)
      end,
        provider: {Alloy.Provider.OpenAI, api_key: "sk-...", model: "gpt-5.4"}
      )

  ## Options

  - `:provider` - `{module, config_keyword_list}` or just `module` (required)
  - `:tools` - list of modules implementing `Alloy.Tool` (default: `[]`)
  - `:system_prompt` - system prompt string (default: `nil`)
  - `:messages` - existing conversation history (default: `[]`)
  - `:max_turns` - maximum agent loop iterations (default: `25`)
  - `:max_tokens` - context window budget for compaction (default: provider model window when known, otherwise `200_000`)
  - `:compaction` - grouped compaction settings like `reserve_tokens`, `keep_recent_tokens`, and `fallback` (default: derived from `:max_tokens`)
  - `:middleware` - list of `Alloy.Middleware` modules (default: `[]`)
  - `:working_directory` - base path for file tools (default: `"."`)
  - `:context` - arbitrary map passed to tools and middleware (default: `%{}`)
  - `:max_pending` - max queued async `send_message/3` requests while one is running (default: `0`)
  - `:model_metadata_overrides` - overrides for model context windows used to derive `:max_tokens` when not set explicitly (default: `%{}`)
  - `:until_tool` - tool name (string) that must be called before the loop completes. If the model signals `:end_turn` without calling this tool, the loop continues with a prompt to call it. Useful for structured output enforcement. (default: `nil`)
  """

  alias Alloy.Agent.{Config, Server, State, Turn}
  alias Alloy.{Message, Result}

  @type result :: Result.t()

  @doc """
  Send a message to a running agent without blocking the caller.

  Non-blocking fire-and-forget. Returns `{:ok, request_id}` immediately.
  Results are broadcast via PubSub. See `Alloy.Agent.Server.send_message/3`
  for full documentation.
  """
  @spec send_message(GenServer.server(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, :busy | :queue_full | :no_pubsub}
  def send_message(server, message, opts \\ [])
  defdelegate send_message(server, message, opts), to: Server

  @doc """
  Cancel an async request by `request_id`.
  """
  @spec cancel_request(GenServer.server(), binary()) :: :ok | {:error, :not_found}
  defdelegate cancel_request(server, request_id), to: Server

  @doc """
  Run the agent loop with a message and options.

  The first argument can be a string (converted to a user message)
  or ignored if `:messages` option provides conversation history.

  Returns `{:ok, result}` on completion or `{:error, result}` on failure.
  """
  @spec run(String.t() | nil, keyword()) :: {:ok, result()} | {:error, result()}
  def run(message \\ nil, opts) do
    do_run(message, opts, [])
  end

  @doc """
  Run the agent loop and stream text deltas as they arrive.

  This is a one-shot convenience API for callers who do not need a persistent
  `Alloy.Agent.Server` process. It returns the same result shape as `run/2`.

  The first argument can be a string (converted to a user message)
  or `nil` if the `:messages` option provides conversation history.

  ## Options

  Accepts the same options as `run/2`, plus:

  - `:on_event` - function called with normalized event envelopes during the run
  """
  @spec stream(String.t() | nil, (String.t() -> any), keyword()) ::
          {:ok, result()} | {:error, result()}
  def stream(message, on_chunk, opts \\ []) when is_function(on_chunk, 1) do
    on_event = validate_on_event(Keyword.get(opts, :on_event))

    turn_opts =
      [streaming: true, on_chunk: on_chunk]
      |> maybe_put(:on_event, on_event)

    do_run(message, opts, turn_opts)
  end

  defp do_run(message, opts, turn_opts) do
    config = Config.from_opts(opts)
    messages = build_messages(message, opts)
    state = %{State.init(config, messages) | status: :running}

    try do
      final_state = Turn.run_loop(state, turn_opts)

      result = Result.from_state(final_state)

      case final_state.status do
        :completed -> {:ok, result}
        :max_turns -> {:ok, result}
        _ -> {:error, result}
      end
    after
      State.cleanup(state)
    end
  end

  defp build_messages(nil, opts) do
    Keyword.get(opts, :messages, [])
  end

  defp build_messages(text, opts) when is_binary(text) do
    existing = Keyword.get(opts, :messages, [])
    existing ++ [Message.user(text)]
  end

  defp validate_on_event(nil), do: nil
  defp validate_on_event(on_event) when is_function(on_event, 1), do: on_event

  defp validate_on_event(bad) do
    raise ArgumentError, "on_event must be a 1-arity function, got: #{inspect(bad)}"
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
