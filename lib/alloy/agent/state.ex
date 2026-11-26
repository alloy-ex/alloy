defmodule Alloy.Agent.State do
  @moduledoc """
  Mutable state for an agent run.

  Tracks the conversation history, turn count, token usage, and
  current status. Passed through each iteration of the agent loop.

  `deadline` is the monotonic time in milliseconds (see
  `System.monotonic_time/1`) with 5 seconds of headroom before `timeout_ms`
  (`run_deadline - 5_000`), or `nil` when `timeout_ms: :infinity`.
  `Alloy.Agent.Turn.run_loop/2` sets it to govern provider retries and give
  non-streaming calls cleanup headroom; `run_deadline` is the absolute
  wall-clock cap (`started + timeout_ms`), or `nil` when `timeout_ms: :infinity`,
  enforced across requests, streaming, tool execution, and turns. Middleware
  inspecting `deadline` or `run_deadline` should guard with `is_integer/1`. Hosts
  wrapping `Alloy.run/2` or `Alloy.stream/3` in `Task.await/2` should give
  their outer await more time than `:timeout_ms` so Alloy can return its own
  `:timeout` result cleanly. Middleware that makes its own provider request,
  as compaction does, uses `deadline` for retry headroom and `run_deadline` as
  the hard wall-clock ceiling (so when `timeout_ms <= 5_000`, summary requests
  run once without retries or fallbacks).
  """

  alias Alloy.Agent.Config
  alias Alloy.{Message, OutputSchema, Usage}
  alias Alloy.Tool.Registry

  @type status :: :idle | :running | :completed | :error | :max_turns | :halted | :cancelled

  @type t :: %__MODULE__{
          config: Config.t(),
          messages: [Message.t()],
          turn: non_neg_integer(),
          usage: Usage.t(),
          status: status(),
          error: term() | nil,
          stop_reason: Alloy.Provider.stop_reason() | nil,
          tool_calls: [map()],
          tool_defs: [map()],
          tool_fns: %{String.t() => Alloy.Tool.Registry.tool()},
          tool_schema_cache: map(),
          provider_state: map(),
          provider_response_metadata: map(),
          run_metadata: map(),
          started_at: integer() | nil,
          deadline: integer() | nil,
          run_deadline: integer() | nil,
          agent_id: String.t()
        }

  @enforce_keys [:config]
  defstruct [
    :config,
    :error,
    :stop_reason,
    messages: [],
    turn: 0,
    usage: %Usage{},
    tool_calls: [],
    status: :idle,
    tool_defs: [],
    tool_fns: %{},
    # Internal, bounded to the latest validated tool set; never part of Result.
    tool_schema_cache: %{},
    provider_state: %{},
    provider_response_metadata: %{},
    run_metadata: %{},
    started_at: nil,
    deadline: nil,
    # Internal absolute monotonic deadline for the whole run (without retry headroom).
    run_deadline: nil,
    agent_id: ""
  ]

  @doc """
  Initialize state from config and optional existing messages.
  """
  @spec init(Config.t(), [Message.t()]) :: t()
  def init(%Config{} = config, messages \\ []) do
    {tool_defs, tool_fns} = Registry.build(config.tools)

    agent_id =
      Map.get(config.context, :session_id) || generate_agent_id()

    %__MODULE__{
      config: config,
      messages: messages,
      tool_defs: tool_defs,
      tool_fns: tool_fns,
      provider_state: Map.get(config.provider_config, :provider_state, %{}),
      started_at: System.monotonic_time(:millisecond),
      agent_id: agent_id
    }
  end

  @doc """
  Prepares request inputs from `:before_completion` middleware.

  Accepts `:messages`, `:tools`, `:system_prompt`, `:provider` (the same
  provider tuple accepted by `Alloy.run/2`), `:output_schema`, and
  `:reasoning`. Changes persist for later turns (updating `:reasoning` overrides
  any earlier primary provider-level `:reasoning`, while fallback providers that
  configured their own explicit `:reasoning` keep theirs).
  Tools and their wire definitions are rebuilt together. Provider changes
  re-derive model limits and discard previous opaque provider state; pass an
  explicit `provider_state` in the new provider config to restore it.
  Run counters, deadlines, usage, and tool history are preserved.
  """
  @spec prepare(t(), keyword()) :: t()
  def prepare(%__MODULE__{} = state, opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :messages,
        :tools,
        :system_prompt,
        :provider,
        :output_schema,
        :reasoning
      ])

    config = prepare_config(state.config, opts)
    {tool_defs, tool_fns} = Registry.build(config.tools)
    messages = Keyword.get(opts, :messages, state.messages)

    unless is_list(messages) and Enum.all?(messages, &is_struct(&1, Message)) do
      raise ArgumentError, "messages must be a list of Alloy.Message structs"
    end

    %{
      state
      | config: config,
        tool_defs: tool_defs,
        tool_fns: tool_fns,
        messages: messages,
        provider_state: prepared_provider_state(state, config),
        provider_response_metadata:
          if(provider_changed?(state.config, config),
            do: %{},
            else: state.provider_response_metadata
          )
    }
  end

  defp prepare_config(config, opts) do
    config =
      case Keyword.fetch(opts, :provider) do
        {:ok, provider} -> Config.with_provider(config, provider)
        :error -> config
      end

    config = %{config | tools: Keyword.get(opts, :tools, config.tools)}
    prompt = Keyword.get(opts, :system_prompt, config.system_prompt)

    unless is_nil(prompt) or is_binary(prompt),
      do: raise(ArgumentError, "system_prompt must be a string or nil")

    output_schema =
      case Keyword.fetch(opts, :output_schema) do
        {:ok, spec} -> OutputSchema.normalize!(spec)
        :error -> config.output_schema
      end

    {reasoning, provider_config} =
      case Keyword.fetch(opts, :reasoning) do
        {:ok, spec} ->
          normalized = Alloy.Provider.normalize_reasoning!(spec)

          # When middleware explicitly updates :reasoning without setting a
          # provider-specific :reasoning in the same call, clear any earlier
          # provider-level :reasoning so the new setting takes effect.
          updated_provider_config =
            if Keyword.has_key?(opts, :provider) and
                 Map.has_key?(config.provider_config, :reasoning),
               do: config.provider_config,
               else: Map.delete(config.provider_config, :reasoning)

          {normalized, updated_provider_config}

        :error ->
          {config.reasoning, config.provider_config}
      end

    %{
      config
      | system_prompt: prompt,
        output_schema: output_schema,
        reasoning: reasoning,
        provider_config: provider_config
    }
  end

  defp prepared_provider_state(state, config) do
    if provider_changed?(state.config, config),
      do: Map.get(config.provider_config, :provider_state, %{}),
      else: state.provider_state
  end

  defp provider_changed?(old, new) do
    old.provider != new.provider or
      Map.delete(old.provider_config, :reasoning) != Map.delete(new.provider_config, :reasoning)
  end

  @doc """
  Append messages to the conversation history.

  `state.messages` always holds the full history in chronological order,
  so middleware can read it directly.
  """
  @spec append_messages(t(), [Message.t()] | Message.t()) :: t()
  def append_messages(%__MODULE__{} = state, messages) when is_list(messages) do
    %{state | messages: state.messages ++ messages}
  end

  def append_messages(%__MODULE__{} = state, %Message{} = message),
    do: append_messages(state, [message])

  @doc """
  Append tool execution metadata for the current run.
  """
  @spec append_tool_calls(t(), [map()]) :: t()
  def append_tool_calls(%__MODULE__{} = state, tool_calls) when is_list(tool_calls) do
    %{state | tool_calls: state.tool_calls ++ tool_calls}
  end

  @doc """
  Merge provider-owned state returned by the model backend.
  """
  @spec merge_provider_state(t(), map() | nil) :: t()
  def merge_provider_state(%__MODULE__{} = state, nil), do: state

  def merge_provider_state(%__MODULE__{} = state, provider_state) when is_map(provider_state) do
    %{state | provider_state: Map.merge(state.provider_state, provider_state)}
  end

  @doc """
  Replace the latest provider response metadata for this run.
  """
  @spec put_provider_response_metadata(t(), map() | nil) :: t()
  def put_provider_response_metadata(%__MODULE__{} = state, nil), do: state

  def put_provider_response_metadata(%__MODULE__{} = state, metadata) when is_map(metadata) do
    %{state | provider_response_metadata: metadata}
  end

  @doc """
  Merge agent-loop runtime metadata for the current run.
  """
  @spec merge_run_metadata(t(), map() | nil) :: t()
  def merge_run_metadata(%__MODULE__{} = state, nil), do: state

  def merge_run_metadata(%__MODULE__{} = state, metadata) when is_map(metadata) do
    %{state | run_metadata: Map.merge(state.run_metadata, metadata)}
  end

  @doc """
  Return the conversation history in chronological order, the same as
  `state.messages`.
  """
  @spec messages(t()) :: [Message.t()]
  def messages(%__MODULE__{messages: messages}), do: messages

  @doc """
  Increment the turn counter.
  """
  @spec increment_turn(t()) :: t()
  def increment_turn(%__MODULE__{} = state) do
    %{state | turn: state.turn + 1}
  end

  @doc """
  Merge usage from a provider response.
  """
  @spec merge_usage(t(), map()) :: t()
  def merge_usage(%__MODULE__{} = state, response_usage) do
    %{state | usage: Usage.merge(state.usage, response_usage)}
  end

  @doc """
  Extract the text from the last assistant message.

  Returns `""` when that message has no text blocks and `nil` when there is
  no assistant message.
  """
  @spec last_assistant_text(t()) :: String.t() | nil
  def last_assistant_text(%__MODULE__{} = state),
    do: find_last_assistant(state, &Message.text/1)

  @doc """
  Extract the thinking/reasoning text from the most recent assistant message
  that carries any. Returns `nil` when no assistant message has thinking.
  """
  @spec last_assistant_thinking(t()) :: String.t() | nil
  def last_assistant_thinking(%__MODULE__{} = state),
    do: find_last_assistant(state, &Message.thinking/1)

  # Newest first, the first assistant message for which `extract` returns a
  # value. Message.text/1 returns "" rather than nil, so text stops at the
  # last assistant message while thinking keeps looking further back.
  defp find_last_assistant(%__MODULE__{} = state, extract) do
    state.messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant} = message -> extract.(message)
      _message -> nil
    end)
  end

  defp generate_agent_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
