defmodule Alloy.Context.Compactor do
  @moduledoc """
  Summary-based context compaction.

  When the conversation approaches the configured reserve threshold, Alloy
  preserves the first message, keeps a recent verbatim token window, and
  replaces older context with a structured handoff summary. If summary
  generation fails, Alloy falls back to deterministic truncation.

  Compaction never splits a tool round: a kept tool result always keeps the
  assistant tool call before it, and truncation keeps the turn in progress
  whole. Because compaction edits earlier history, it removes every
  `thinking` and `redacted_thinking` block it keeps, including the turn in
  progress: signed thinking is bound to the history it was produced after.
  Under manual thinking (`"type" => "enabled"` in `:extra_body`), which
  requires the turn in progress to start with thinking and whose models do
  not check history, that turn keeps its thinking. If the compacted request
  is still
  over budget, the largest retained tool results are shortened, keeping
  their beginning and a `[tool result truncated: ...]` marker.

  Compaction options live under `compaction:`:

    * `:clear_tool_results` - clear old bulky tool-result content before
      summary generation (default `true`)
    * `:keep_recent_tool_results` - newest tool results to preserve verbatim
      when clearing (default `3`)
    * `:summary_system_prompt` - system prompt used for summary generation
    * `:summary_prompt` - user prompt instructions appended after the
      serialized conversation
  """

  @behaviour Alloy.Middleware

  alias Alloy.Agent.State
  alias Alloy.Context.Compactor.Estimator
  alias Alloy.Internal.Sanitize
  alias Alloy.{Message, Middleware}
  alias Alloy.Provider.Retry

  require Logger

  @default_keep_recent 10
  @truncate_length 200

  @summary_prefix "Previous analysis summary (from earlier in this session):"
  @cleared_prefix "[tool result cleared: "

  # A shrunk tool result keeps at least this much of its beginning; the
  # marker appended after it is about this long.
  @min_kept_result_bytes 2_000
  @truncation_marker_bytes 64

  # Provider config keys that tie requests to session continuity, force tool
  # selection, or enable server-side/built-in tools are stripped from compaction
  # summary requests (primary and fallbacks). Privacy settings such as `:store`
  # and `:extra_body["store"]` are preserved.
  @summary_stripped_provider_keys [
    :provider_state,
    "provider_state",
    :persist_session,
    "persist_session",
    :previous_response_id,
    "previous_response_id",
    :tool_choice,
    "tool_choice",
    :parallel_tool_calls,
    "parallel_tool_calls",
    :built_in_tools,
    "built_in_tools",
    :web_search,
    "web_search",
    :x_search,
    "x_search",
    :server_tools,
    "server_tools",
    :code_execution,
    "code_execution",
    :tool_config,
    "tool_config"
  ]

  # extra_body keys that alter thinking, tools, context editing, or output
  # shape are incompatible with plain text summary generation. Other caller
  # keys (for example `"store" => false` for zero data retention) are kept.
  @summary_stripped_extra_body_keys [
    :thinking,
    "thinking",
    :reasoning,
    "reasoning",
    :tools,
    "tools",
    :tool_choice,
    "tool_choice",
    :tool_config,
    "tool_config",
    :toolConfig,
    "toolConfig",
    :context_management,
    "context_management",
    :output_config,
    "output_config",
    :response_format,
    "response_format",
    :text,
    "text",
    :previous_response_id,
    "previous_response_id"
  ]

  # Gemini generationConfig keys that force structured output or thinking
  # interfere with plain-text handoff summaries.
  @summary_stripped_generation_config_keys [
    :responseSchema,
    "responseSchema",
    :response_schema,
    "response_schema",
    :responseJsonSchema,
    "responseJsonSchema",
    :response_json_schema,
    "response_json_schema",
    :responseMimeType,
    "responseMimeType",
    :response_mime_type,
    "response_mime_type",
    :thinkingConfig,
    "thinkingConfig",
    :thinking_config,
    "thinking_config"
  ]

  @summary_system_prompt """
  You are performing CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

  Include:
  - Current progress and key decisions made
  - Important context, constraints, or user preferences
  - What remains to be done (clear next steps)
  - Any critical data, examples, or references needed to continue

  Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
  """

  @summary_prompt """
  Create a structured handoff summary for another language model that will resume this task.

  Use this EXACT structure:

  ## Goal
  [What the user is trying to accomplish]

  ## Constraints & Preferences
  - [Important constraints, preferences, or requirements]
  - [(none) if not applicable]

  ## Progress
  ### Done
  - [Completed tasks, findings, or verified facts]

  ### In Progress
  - [Current work that is not finished yet]

  ### Blocked
  - [Active blockers or "(none)"]

  ## Key Decisions
  - **[Decision]**: [Brief rationale]

  ## Evidence & References
  - [Evidence chains, exact file paths, tool names, function names, or error messages]
  - [(none) if not applicable]

  ## Next Steps
  1. [Ordered next action]

  ## Critical Context
  - [Anything the next model must preserve exactly]
  - [(none) if not applicable]

  Requirements:
  - Preserve exact file paths, function names, tool names, error messages, and user preferences.
  - Preserve evidence chains and clearly mark when a conclusion depends on a specific source or tool result.
  - Only include information supported by the provided conversation and previous summary.
  - Keep the summary concise but decision-complete enough for the next model to continue without rereading the discarded messages.
  """

  @doc false
  @spec default_summary_system_prompt() :: String.t()
  def default_summary_system_prompt, do: @summary_system_prompt

  @doc false
  @spec default_summary_prompt() :: String.t()
  def default_summary_prompt, do: @summary_prompt

  @doc """
  Prefix used for synthetic handoff summary messages inserted by the compactor.
  """
  @spec summary_prefix() :: String.t()
  def summary_prefix, do: @summary_prefix

  @doc """
  Compaction as middleware.

  On `:before_completion` it compacts when the history nears the budget;
  on `:on_context_overflow` (the provider rejected the request as too long)
  it compacts regardless of the estimate. Either way, when the messages
  changed it emits `[:alloy, :compaction, :done]` and runs the
  `:after_compaction` hook. Every other hook returns the state unchanged.
  """
  @impl Middleware
  @spec call(Middleware.hook(), State.t()) :: State.t() | {:halt, String.t(), State.t()}
  def call(:before_completion, %State{} = state) do
    case maybe_compact(state) do
      {:unchanged, unchanged} ->
        unchanged

      {:compacted, %State{messages: messages} = compacted} when messages == state.messages ->
        compacted

      {:compacted, compacted} ->
        after_compaction(state, compacted)
    end
  end

  def call(:on_context_overflow, %State{} = state) do
    case force_compact(state) do
      %State{messages: messages} = compacted when messages == state.messages -> compacted
      compacted -> after_compaction(state, compacted)
    end
  end

  def call(_hook, state), do: state

  defp after_compaction(%State{} = before, %State{} = compacted) do
    :telemetry.execute(
      [:alloy, :compaction, :done],
      %{messages_before: length(before.messages), messages_after: length(compacted.messages)},
      %{turn: before.turn + 1}
    )

    # A halt in :after_compaction still keeps the compaction and the usage
    # of its summary request, so it is passed on with that state.
    case Middleware.run_hook(:after_compaction, compacted) do
      {:halted, reason, halted} -> {:halt, reason, halted}
      %State{} = state -> state
    end
  end

  @doc """
  Forces compaction regardless of reserve budget.
  Used when the provider rejects the prompt as too long.

  The token estimate is not trusted here, because the provider has just
  rejected a prompt the estimate allowed: clearing old tool results is
  always followed by summarization (or truncation).

  Accepts the same options as `maybe_compact/2`.
  """
  @spec force_compact(State.t(), keyword()) :: State.t()
  def force_compact(%State{} = state, opts \\ []) do
    original = State.messages(state)
    {_fits_estimate, messages} = maybe_clear_tool_results(original, state, opts)
    {state, compacted} = summarize_or_fallback(state, messages, opts)
    finalize(state, compacted, force_shrink?: compacted == original)
  end

  @doc """
  Compacts state messages when the estimated prompt exceeds
  `max_tokens - reserve_tokens`.

  The estimate counts the system prompt, the tool definitions and every
  message at roughly four bytes per token.

  The summary is requested through `Alloy.Provider.Retry` (retries,
  backoff and fallback providers), and its token usage is added to
  `state.usage`.

  ## Options

    * `:turn` - turn number reported in compaction telemetry
      (default: `state.turn + 1`)
    * `:deadline` - monotonic time in milliseconds by which the summary
      request must finish (default: `state.deadline`, or now plus
      `config.timeout_ms` when that is unset)

  Returns `{:compacted, state}` when compaction occurred, or
  `{:unchanged, state}` when already within budget.
  """
  @spec maybe_compact(State.t(), keyword()) :: {:compacted | :unchanged, State.t()}
  def maybe_compact(%State{} = state, opts \\ []) do
    messages = State.messages(state)

    if Estimator.within_reserve?(messages, state) do
      {:unchanged, state}
    else
      {:compacted, compact_messages_in_state(state, messages, opts)}
    end
  end

  # Splits messages into {first, middle, recent} for truncation compaction.
  # The middle slice is what gets compacted; first and recent are preserved.
  defp split_messages([first | rest], keep_recent) do
    {middle, recent} = Enum.split(rest, max(length(rest) - keep_recent, 0))
    {middle, recent} = extend_to_round_start(middle, recent)
    {first, middle, recent}
  end

  # A kept tool result needs the assistant tool call before it, so the kept
  # window never starts in the middle of a tool round.
  defp extend_to_round_start(middle, [head | _] = recent) when middle != [] do
    if tool_result_message?(head) do
      {earlier, [call]} = Enum.split(middle, -1)
      extend_to_round_start(earlier, [call | recent])
    else
      {middle, recent}
    end
  end

  defp extend_to_round_start(middle, recent), do: {middle, recent}

  defp compact_messages_in_state(%State{} = state, messages, opts) do
    {state, compacted} =
      case maybe_clear_tool_results(messages, state, opts) do
        {:done, cleared_messages} -> {state, cleared_messages}
        {:continue, messages} -> summarize_or_fallback(state, messages, opts)
      end

    finalize(state, compacted)
  end

  # Every compaction path edits earlier history, so signed thinking kept
  # after the edit no longer matches the history it was produced after, and
  # Claude Fable 5.1, Opus 5.5, Sonnet 5.5 and Haiku 5.5 reject it for
  # accounts created on or after 2026-08-31. That includes the turn in
  # progress. Removing all of it is a documented valid change, and those
  # models think adaptively, which does not require the turn in progress to
  # start with thinking. Manual thinking ("enabled" with a budget) does
  # require it, and the models that accept manual thinking do not check the
  # history, so there the turn in progress keeps its thinking. See
  # https://platform.claude.com/docs/en/build-with-claude/preserved-thinking
  defp finalize(%State{} = state, messages, opts \\ []) do
    force_shrink? = Keyword.get(opts, :force_shrink?, false)

    messages =
      messages
      |> strip_thinking(manual_thinking?(state))
      |> fit_tool_results(state, force_shrink?)

    %{state | messages: messages}
  end

  defp strip_thinking(messages, false = _manual?), do: Enum.flat_map(messages, &drop_thinking/1)

  defp strip_thinking(messages, true = _manual?) do
    {settled, in_flight} = Enum.split(messages, in_flight_start(messages))
    Enum.flat_map(settled, &drop_thinking/1) ++ in_flight
  end

  # extra_body is merged into the request with its keys stringified, so the
  # caller may have written either form.
  defp manual_thinking?(%State{config: %{provider_config: provider_config}}) do
    case Map.get(provider_config, :extra_body) do
      %{"thinking" => thinking} -> manual_type?(thinking)
      %{thinking: thinking} -> manual_type?(thinking)
      _extra_body -> false
    end
  end

  defp manual_type?(%{"type" => "enabled"}), do: true
  defp manual_type?(%{type: "enabled"}), do: true
  defp manual_type?(_thinking), do: false

  # The turn in progress is everything after the last real user message; a
  # conversation that ends with one has no turn in progress.
  defp in_flight_start(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.reduce(0, fn {message, next_index}, start ->
      if real_user_message?(message), do: next_index, else: start
    end)
  end

  # A message left with no content would be rejected, and a message holding
  # only thinking says nothing once the thinking is gone.
  defp drop_thinking(%Message{content: []}), do: []

  defp drop_thinking(%Message{content: blocks} = message) when is_list(blocks) do
    case Enum.reject(blocks, &Estimator.thinking_block?/1) do
      ^blocks -> [message]
      [] -> []
      kept -> [%{message | content: kept}]
    end
  end

  defp drop_thinking(message), do: [message]

  # Last resort when the compacted request is still over budget, typically
  # one huge result in the round in progress: shrink the largest retained
  # tool results, keeping their beginning and a marker, until it fits.
  # Under forced overflow recovery, when clearing and summarization could not
  # change the messages at all (e.g. a single turn with dense code/CJK tool
  # output that fooled the bytes/4 estimate), shrink large tool results
  # unconditionally so the retry makes progress.
  defp fit_tool_results(messages, %State{} = state, force_shrink?) do
    case Estimator.request_tokens(messages, state) - Estimator.budget_tokens(state) do
      overflow when overflow > 0 ->
        shrink_tool_results(messages, overflow * 4)

      _fits when force_shrink? ->
        force_shrink_tool_results(messages)

      _fits ->
        messages
    end
  end

  defp force_shrink_tool_results(messages) do
    shrinkable = shrinkable_results(messages)

    total_reducible =
      Enum.reduce(shrinkable, 0, fn {_pos, bytes}, acc ->
        acc + max(bytes - @min_kept_result_bytes - @truncation_marker_bytes, 0)
      end)

    if total_reducible > 0 do
      shrink_tool_results(messages, max(div(total_reducible, 2), 1))
    else
      messages
    end
  end

  defp shrink_tool_results(messages, excess_bytes) do
    {targets, _remaining} =
      messages
      |> shrinkable_results()
      |> Enum.sort_by(fn {_position, bytes} -> bytes end, :desc)
      |> Enum.reduce_while({%{}, excess_bytes}, fn {position, bytes}, {targets, remaining} ->
        keep = max(@min_kept_result_bytes, bytes - remaining - @truncation_marker_bytes)
        targets = Map.put(targets, position, keep)
        remaining = remaining - (bytes - keep - @truncation_marker_bytes)
        if remaining > 0, do: {:cont, {targets, remaining}}, else: {:halt, {targets, remaining}}
      end)

    messages
    |> Enum.with_index()
    |> Enum.map(fn {message, message_index} ->
      shrink_results_in_message(message, message_index, targets)
    end)
  end

  defp shrinkable_results(messages) do
    for {%Message{content: blocks}, message_index} when is_list(blocks) <-
          Enum.with_index(messages),
        {%{type: type, content: content}, block_index} <- Enum.with_index(blocks),
        type in ["tool_result", "server_tool_result"],
        is_binary(content),
        byte_size(content) > @min_kept_result_bytes + @truncation_marker_bytes do
      {{message_index, block_index}, byte_size(content)}
    end
  end

  defp shrink_results_in_message(%Message{content: blocks} = message, message_index, targets)
       when is_list(blocks) do
    blocks =
      blocks
      |> Enum.with_index()
      |> Enum.map(fn {block, block_index} ->
        case Map.fetch(targets, {message_index, block_index}) do
          {:ok, keep} -> %{block | content: truncate_result(block.content, keep)}
          :error -> block
        end
      end)

    %{message | content: blocks}
  end

  defp shrink_results_in_message(message, _message_index, _targets), do: message

  defp truncate_result(content, keep_bytes) do
    head = content |> binary_part(0, keep_bytes) |> trim_partial_codepoint(3)

    head <>
      "\n\n[tool result truncated: kept #{byte_size(head)} of #{byte_size(content)} bytes]"
  end

  # A byte cut can split a multi-byte UTF-8 character; drop its leading bytes.
  defp trim_partial_codepoint(binary, 0), do: binary

  defp trim_partial_codepoint(binary, attempts) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_partial_codepoint(attempts - 1)
    end
  end

  defp maybe_clear_tool_results(
         messages,
         %State{
           turn: turn,
           config: %{
             compaction:
               %{
                 clear_tool_results: true,
                 keep_recent_tokens: keep_recent_tokens
               } = compaction
           }
         } = state,
         opts
       ) do
    keep_recent_tool_results = Map.get(compaction, :keep_recent_tool_results, 3)
    telemetry_turn = Keyword.get(opts, :turn, turn + 1)

    {cleared_messages, cleared} =
      clear_tool_results(messages,
        keep_recent_tokens: keep_recent_tokens,
        keep_recent_tool_results: keep_recent_tool_results
      )

    if cleared.results_cleared > 0 do
      :telemetry.execute(
        [:alloy, :compaction, :cleared],
        cleared,
        %{turn: telemetry_turn}
      )

      if Estimator.within_reserve?(cleared_messages, state) do
        {:done, cleared_messages}
      else
        {:continue, cleared_messages}
      end
    else
      {:continue, messages}
    end
  end

  defp maybe_clear_tool_results(messages, _state, _opts), do: {:continue, messages}

  defp summarize_or_fallback(%State{} = state, messages, opts) do
    keep_recent_tokens = state.config.compaction.keep_recent_tokens

    case prepare_summary_compaction(messages, keep_recent_tokens) do
      {:ok, prepared} ->
        fire_on_compaction(prepared.messages_to_summarize, state)
        {result, usage} = summarize_compaction(prepared, state, opts)
        state = State.merge_usage(state, usage)

        case result do
          {:ok, summary_text} ->
            {state, [prepared.first, build_summary_message(summary_text) | prepared.recent]}

          {:error, reason} ->
            Logger.warning(
              "summary compaction failed, falling back to truncation: #{inspect(reason)}"
            )

            {state, fallback_compact(state, messages)}
        end

      :noop ->
        {state, fallback_compact(state, messages)}
    end
  end

  defp clear_tool_results(messages, opts) do
    keep_recent_tokens = Keyword.fetch!(opts, :keep_recent_tokens)
    keep_recent_tool_results = Keyword.fetch!(opts, :keep_recent_tool_results)
    old_indexes = MapSet.new(old_message_indexes(messages, keep_recent_tokens))

    result_positions = tool_result_positions(messages)

    keep_positions =
      result_positions
      |> Enum.take(-keep_recent_tool_results)
      |> Enum.map(fn %{message_index: message_index, block_index: block_index} ->
        {message_index, block_index}
      end)
      |> MapSet.new()

    {cleared_messages, cleared} =
      messages
      |> Enum.with_index()
      |> Enum.map_reduce(%{results_cleared: 0, bytes_cleared: 0}, fn {message, message_index},
                                                                     acc ->
        if MapSet.member?(old_indexes, message_index) do
          clear_tool_results_in_message(message, message_index, keep_positions, acc)
        else
          {message, acc}
        end
      end)

    {cleared_messages, cleared}
  end

  defp old_message_indexes([_first | rest], keep_recent_tokens) do
    {previous_summary, tail} = pop_existing_summary(rest)
    offset = if previous_summary, do: 2, else: 1

    if tail == [] do
      []
    else
      cut_index = find_cut_point(tail, keep_recent_tokens)

      if cut_index > 0 do
        offset..(offset + cut_index - 1)//1 |> Enum.to_list()
      else
        []
      end
    end
  end

  defp old_message_indexes(_, _keep_recent_tokens), do: []

  defp tool_result_positions(messages) do
    messages
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%Message{content: blocks}, message_index} when is_list(blocks) ->
        blocks
        |> Enum.with_index()
        |> Enum.flat_map(fn
          {%{type: type} = block, block_index}
          when type in ["tool_result", "server_tool_result"] ->
            [
              %{
                message_index: message_index,
                block_index: block_index,
                bytes: content_bytes(block)
              }
            ]

          _ ->
            []
        end)

      _ ->
        []
    end)
  end

  defp clear_tool_results_in_message(
         %Message{content: blocks} = message,
         message_index,
         keep_positions,
         acc
       )
       when is_list(blocks) do
    {blocks, acc} =
      blocks
      |> Enum.with_index()
      |> Enum.map_reduce(acc, fn
        # Clearing it again would replace the original size with the size of
        # the marker and change bytes the provider has already cached.
        {%{content: @cleared_prefix <> _} = block, _block_index}, acc ->
          {block, acc}

        {%{type: type} = block, block_index}, acc
        when type in ["tool_result", "server_tool_result"] ->
          position = {message_index, block_index}

          if MapSet.member?(keep_positions, position) do
            {block, acc}
          else
            bytes = content_bytes(block)

            {
              %{block | content: "#{@cleared_prefix}#{bytes} bytes]"},
              %{
                results_cleared: acc.results_cleared + 1,
                bytes_cleared: acc.bytes_cleared + bytes
              }
            }
          end

        {block, _block_index}, acc ->
          {block, acc}
      end)

    {%{message | content: blocks}, acc}
  end

  defp clear_tool_results_in_message(message, _message_index, _keep_positions, acc),
    do: {message, acc}

  defp content_bytes(%{content: content}) when is_binary(content), do: byte_size(content)
  defp content_bytes(%{content: content}), do: content |> inspect() |> byte_size()
  defp content_bytes(_block), do: 0

  # The turn in progress is always kept whole, so its tool calls and results
  # stay together. If it is too large on its own, fit_tool_results/2 shrinks
  # its biggest results afterwards.
  defp fallback_compact(%State{config: %{compaction: %{fallback: :truncate}}}, messages) do
    count = length(messages)
    in_flight_count = count - in_flight_start(messages)
    keep_recent = max(min(@default_keep_recent, max(1, count - 2)), in_flight_count)
    compact_messages(messages, keep_recent: keep_recent)
  end

  defp prepare_summary_compaction([first | rest], keep_recent_tokens) do
    {previous_summary, tail} = pop_existing_summary(rest)

    if tail == [] do
      :noop
    else
      cut_index = find_cut_point(tail, keep_recent_tokens)
      messages_to_summarize = Enum.take(tail, cut_index)
      recent = Enum.drop(tail, cut_index)

      if messages_to_summarize == [] do
        :noop
      else
        {:ok,
         %{
           first: first,
           previous_summary: previous_summary,
           messages_to_summarize: messages_to_summarize,
           recent: recent
         }}
      end
    end
  end

  defp prepare_summary_compaction(_, _keep_recent_tokens), do: :noop

  defp pop_existing_summary([message | rest]) do
    if summary_message?(message), do: {message, rest}, else: {nil, [message | rest]}
  end

  defp pop_existing_summary([]), do: {nil, []}

  defp sanitize_summary_provider_config(provider_config) when is_map(provider_config) do
    provider_config
    |> Map.drop(@summary_stripped_provider_keys)
    |> sanitize_generation_config_key(:generation_config)
    |> sanitize_generation_config_key("generation_config")
    |> sanitize_summary_extra_body()
  end

  defp sanitize_summary_extra_body(config) do
    config
    |> sanitize_extra_body_key(:extra_body)
    |> sanitize_extra_body_key("extra_body")
  end

  defp sanitize_extra_body_key(config, key) do
    case Map.get(config, key) do
      extra when is_map(extra) ->
        cleaned =
          extra
          |> Map.drop(@summary_stripped_extra_body_keys)
          |> sanitize_generation_config_key(:generationConfig)
          |> sanitize_generation_config_key("generationConfig")
          |> sanitize_generation_config_key(:generation_config)
          |> sanitize_generation_config_key("generation_config")

        if cleaned == %{}, do: Map.delete(config, key), else: Map.put(config, key, cleaned)

      _other ->
        Map.delete(config, key)
    end
  end

  defp sanitize_generation_config_key(map, key) do
    case Map.get(map, key) do
      gen_cfg when is_map(gen_cfg) ->
        cleaned = Map.drop(gen_cfg, @summary_stripped_generation_config_keys)
        if cleaned == %{}, do: Map.delete(map, key), else: Map.put(map, key, cleaned)

      _other ->
        map
    end
  end

  # Returns {result, usage}: the summary call is billed even when its output
  # is unusable, so its usage is reported either way.
  defp summarize_compaction(prepared, %State{} = state, opts) do
    opt_deadline = Keyword.get(opts, :deadline)
    hard_deadline = min_deadline(opt_deadline, state.run_deadline)

    default_deadline =
      case state.config.timeout_ms do
        :infinity -> nil
        timeout_ms -> System.monotonic_time(:millisecond) + timeout_ms
      end

    deadline =
      (min_deadline(opt_deadline, state.deadline) || default_deadline)
      |> min_deadline(hard_deadline)

    config =
      state.config.provider_config
      |> sanitize_summary_provider_config()
      |> Map.put(
        :system_prompt,
        Map.get(
          state.config.compaction,
          :summary_system_prompt,
          default_summary_system_prompt()
        )
      )
      |> then(fn cfg ->
        if is_integer(hard_deadline),
          do: Map.put(cfg, :alloy_request_deadline, hard_deadline),
          else: cfg
      end)

    prompt =
      build_summary_prompt(
        prepared.messages_to_summarize,
        prepared.previous_summary,
        Map.get(state.config.compaction, :summary_prompt, default_summary_prompt())
      )

    sanitized_fallbacks =
      Enum.map(state.config.fallback_providers, fn {fb_provider, fb_config} ->
        {fb_provider, sanitize_summary_provider_config(fb_config)}
      end)

    # The summary goes through Retry like any turn request, so it gets the
    # same retries, sanitized fallback providers and receive timeout, bounded
    # by the caller's deadline.
    summary_state = %{
      state
      | config: %{state.config | fallback_providers: sanitized_fallbacks},
        messages: [Message.user(prompt)],
        tool_defs: []
    }

    no_chunks = fn _chunk -> :ok end

    case Retry.call_with_retry(
           summary_state,
           state.config.provider,
           config,
           false,
           no_chunks,
           deadline
         ) do
      {:ok, response} -> {extract_summary_text(response), Map.get(response, :usage, %{})}
      {:error, reason} -> {{:error, reason}, %{}}
    end
  end

  defp min_deadline(nil, b), do: b
  defp min_deadline(a, nil), do: a
  defp min_deadline(a, b), do: min(a, b)

  defp build_summary_prompt(messages_to_summarize, previous_summary, summary_prompt) do
    previous_summary_section =
      case previous_summary do
        nil ->
          ""

        %Message{} = message ->
          "<previous-summary>\n#{summary_body(message)}\n</previous-summary>\n\n"
      end

    """
    #{previous_summary_section}<conversation>
    #{Estimator.serialize_messages(messages_to_summarize)}
    </conversation>

    #{summary_prompt}
    """
  end

  defp extract_summary_text(%{messages: messages}) when is_list(messages) do
    summary_text =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Message{role: :assistant} = message ->
          case Message.text(message) |> String.trim() do
            "" -> nil
            text -> text
          end

        _ ->
          nil
      end)

    if summary_text do
      {:ok, summary_text}
    else
      {:error, :empty_summary}
    end
  end

  defp extract_summary_text(_response), do: {:error, :invalid_summary_response}

  defp build_summary_message(summary_text) do
    %Message{role: :user, content: "#{@summary_prefix}\n#{String.trim(summary_text)}"}
  end

  defp summary_message?(%Message{role: :user, content: content}) when is_binary(content) do
    String.starts_with?(content, @summary_prefix)
  end

  defp summary_message?(_message), do: false

  defp summary_body(%Message{content: content}) when is_binary(content) do
    content
    |> String.replace_prefix(@summary_prefix, "")
    |> String.trim()
  end

  defp find_cut_point(messages, keep_recent_tokens) when is_list(messages) and messages != [] do
    indexed = List.to_tuple(messages)
    last_index = tuple_size(indexed) - 1
    threshold_index = find_threshold_index(indexed, last_index, keep_recent_tokens)

    user_cut =
      Enum.find(threshold_index..last_index, fn index ->
        real_user_message?(elem(indexed, index))
      end)

    assistant_cut =
      Enum.find(threshold_index..last_index, fn index ->
        assistant_message?(elem(indexed, index))
      end)

    fallback_cut =
      Enum.find(threshold_index..0//-1, fn index ->
        valid_cut_message?(elem(indexed, index))
      end)

    user_cut || assistant_cut || fallback_cut || 0
  end

  defp find_cut_point(_messages, _keep_recent_tokens), do: 0

  defp find_threshold_index(indexed, max_index, keep_recent_tokens) do
    Enum.reduce_while(max_index..0//-1, {0, 0}, fn index,
                                                   {_threshold_index, accumulated_tokens} ->
      accumulated_tokens =
        accumulated_tokens + Estimator.estimate_message_tokens(elem(indexed, index))

      if accumulated_tokens >= keep_recent_tokens do
        {:halt, {index, accumulated_tokens}}
      else
        {:cont, {0, accumulated_tokens}}
      end
    end)
    |> elem(0)
  end

  defp real_user_message?(%Message{role: :user} = message) do
    not tool_result_message?(message) and not summary_message?(message)
  end

  defp real_user_message?(_message), do: false

  defp assistant_message?(%Message{role: :assistant}), do: true
  defp assistant_message?(_message), do: false

  defp valid_cut_message?(message), do: real_user_message?(message) or assistant_message?(message)

  defp tool_result_message?(%Message{role: :user, content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_result", "server_tool_result"] -> true
      _ -> false
    end)
  end

  defp tool_result_message?(_message), do: false

  # Fires the on_compaction callback with the messages that are about to be
  # summarized. Any crash in the callback is swallowed — compaction must always proceed.
  defp fire_on_compaction(_middle, %State{config: %{on_compaction: nil}}), do: :ok

  defp fire_on_compaction(
         middle,
         %State{config: %{on_compaction: callback}} = state
       )
       when is_function(callback, 2) do
    callback.(middle, state)
  rescue
    e ->
      stacktrace = Sanitize.stacktrace(__STACKTRACE__)

      Logger.warning(
        "on_compaction callback crashed: #{Exception.message(e)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(stacktrace)}"
      )

      :ok
  catch
    kind, payload ->
      stacktrace = Sanitize.stacktrace(__STACKTRACE__)

      Logger.warning(
        "on_compaction callback error (#{kind}): #{Sanitize.inspect_bounded(payload)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(stacktrace)}"
      )

      :ok
  end

  defp fire_on_compaction(_, _), do: :ok

  @doc """
  Compacts messages, preserving the first message and the most recent N messages.

  This helper intentionally stays deterministic and provider-free so it can serve
  as the fallback truncation strategy.

  The preserved window never starts with a tool result: it is extended back to
  the assistant message that made the call, so it may hold more than N messages.

  ## Options
    * `:keep_recent` - minimum number of recent messages to preserve (default #{@default_keep_recent})
  """
  @spec compact_messages([Message.t()], keyword()) :: [Message.t()]
  def compact_messages(messages, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    count = length(messages)

    if count <= keep_recent + 1 do
      messages
    else
      {first, middle, recent} = split_messages(messages, keep_recent)
      compacted_middle = Enum.flat_map(middle, &compact_message/1)
      [first | compacted_middle] ++ recent
    end
  end

  defp compact_message(%Message{content: blocks} = msg) when is_list(blocks) do
    compacted_blocks =
      Enum.map(blocks, fn
        %{type: type} = block when type in ["tool_result", "server_tool_result"] ->
          %{block | content: "[compacted]"}

        %{type: "thinking", signature: signature} when is_binary(signature) ->
          nil

        %{type: "redacted_thinking"} ->
          nil

        %{type: "thinking", thinking: text} = block when byte_size(text) > @truncate_length ->
          %{block | thinking: String.slice(text, 0, @truncate_length) <> "..."}

        block ->
          block
      end)
      |> Enum.reject(&is_nil/1)

    case compacted_blocks do
      [] -> []
      kept -> [%{msg | content: kept}]
    end
  end

  defp compact_message(%Message{role: :assistant, content: text} = msg) when is_binary(text) do
    if String.length(text) > @truncate_length do
      [%{msg | content: String.slice(text, 0, @truncate_length) <> "..."}]
    else
      [msg]
    end
  end

  defp compact_message(msg), do: [msg]
end
