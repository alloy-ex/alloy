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
  is still over budget, the largest retained tool results are shortened,
  keeping their beginning and a `[tool result truncated: ...]` marker.

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
  alias Alloy.Cancel
  alias Alloy.Context.Compactor.{Estimator, Summary}
  alias Alloy.Internal.Sanitize
  alias Alloy.{Message, Middleware}
  alias Alloy.Provider.Error

  require Logger

  @default_keep_recent 10
  @truncate_length 200

  @cleared_prefix "[tool result cleared: "

  # A shrunk tool result keeps at least this much of its beginning; the
  # marker appended after it is about this long.
  @min_kept_result_bytes 2_000
  @truncation_marker_bytes 64

  @doc false
  @spec default_summary_system_prompt() :: String.t()
  def default_summary_system_prompt, do: Summary.default_system_prompt()

  @doc false
  @spec default_summary_prompt() :: String.t()
  def default_summary_prompt, do: Summary.default_prompt()

  @doc """
  Prefix used for synthetic handoff summary messages inserted by the compactor.
  """
  @spec summary_prefix() :: String.t()
  def summary_prefix, do: Summary.prefix()

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

    if Cancel.cancelled?(state.config.cancel_token) do
      cancel_compaction_state(state, original, nil)
    else
      {_fits_estimate, messages} = maybe_clear_tool_results(original, state, opts)

      case summarize_or_fallback(state, messages, opts) do
        {:cancelled, next_state, err} ->
          cancel_compaction_state(next_state, original, err)

        {:ok, next_state, compacted} ->
          finalize_or_cancel(next_state, compacted, original,
            force_shrink?: compacted == original
          )
      end
    end
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

    cond do
      Cancel.cancelled?(state.config.cancel_token) ->
        {:unchanged, cancel_compaction_state(state, messages, nil)}

      Estimator.within_reserve?(messages, state) ->
        {:unchanged, state}

      true ->
        compacted = compact_messages_in_state(state, messages, opts)

        cond do
          compacted.status == :cancelled ->
            {:unchanged, compacted}

          Cancel.cancelled?(compacted.config.cancel_token) ->
            {:unchanged, cancel_compaction_state(compacted, messages, nil)}

          true ->
            {:compacted, compacted}
        end
    end
  end

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
    if Summary.tool_result_message?(head) do
      {earlier, [call]} = Enum.split(middle, -1)
      extend_to_round_start(earlier, [call | recent])
    else
      {middle, recent}
    end
  end

  defp extend_to_round_start(middle, recent), do: {middle, recent}

  defp compact_messages_in_state(%State{} = state, messages, opts) do
    original = messages

    case maybe_clear_tool_results(messages, state, opts) do
      {:done, cleared_messages} ->
        finalize_or_cancel(state, cleared_messages, original)

      {:continue, cleared_or_orig} ->
        case summarize_or_fallback(state, cleared_or_orig, opts) do
          {:cancelled, next_state, err} -> cancel_compaction_state(next_state, original, err)
          {:ok, next_state, compacted} -> finalize_or_cancel(next_state, compacted, original)
        end
    end
  end

  defp finalize_or_cancel(state, compacted, original, opts \\ []) do
    if Cancel.cancelled?(state.config.cancel_token) do
      cancel_compaction_state(state, original, nil)
    else
      finalized = finalize(state, compacted, opts)

      if Cancel.cancelled?(finalized.config.cancel_token),
        do: cancel_compaction_state(finalized, original, nil),
        else: finalized
    end
  end

  defp cancel_compaction_state(state, original, err) do
    %{State.put_provider_error(state, err) | messages: original}
    |> State.cancel()
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
  defp finalize(%State{} = state, messages, opts) do
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
      if Summary.real_user_message?(message), do: next_index, else: start
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
    head = Sanitize.cap_bytes(content, keep_bytes)

    head <>
      "\n\n[tool result truncated: kept #{byte_size(head)} of #{byte_size(content)} bytes]"
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

    if Cancel.cancelled?(state.config.cancel_token) do
      {:cancelled, state, nil}
    else
      do_summarize_or_fallback(state, messages, keep_recent_tokens, opts)
    end
  end

  defp do_summarize_or_fallback(state, messages, keep_recent_tokens, opts) do
    case Summary.prepare(messages, keep_recent_tokens) do
      {:ok, prepared} ->
        fire_on_compaction(prepared.messages_to_summarize, state)

        if Cancel.cancelled?(state.config.cancel_token) do
          {:cancelled, state, nil}
        else
          {result, usage} = Summary.summarize(prepared, state, opts)
          state = State.merge_usage(state, usage)

          handle_summary_result(result, state, prepared, messages)
        end

      :noop ->
        if Cancel.cancelled?(state.config.cancel_token),
          do: {:cancelled, state, nil},
          else: {:ok, state, fallback_compact(state, messages)}
    end
  end

  defp handle_summary_result(
         {:error, %Error{kind: :cancelled} = err},
         state,
         _prepared,
         _messages
       ) do
    {:cancelled, state, err}
  end

  defp handle_summary_result(result, state, prepared, messages) do
    if Cancel.cancelled?(state.config.cancel_token) do
      {:cancelled, state, nil}
    else
      case result do
        {:ok, summary_text} ->
          {:ok, state, [prepared.first, Summary.build_message(summary_text) | prepared.recent]}

        {:error, reason} ->
          Logger.warning(
            "summary compaction failed, falling back to truncation: #{Sanitize.inspect_bounded(reason)}"
          )

          {:ok, state, fallback_compact(state, messages)}
      end
    end
  end

  defp clear_tool_results(messages, opts) do
    keep_recent_tokens = Keyword.fetch!(opts, :keep_recent_tokens)
    keep_recent_tool_results = Keyword.fetch!(opts, :keep_recent_tool_results)

    case old_message_bounds(messages, keep_recent_tokens) do
      nil ->
        {messages, %{results_cleared: 0, bytes_cleared: 0}}

      {first_old, last_old} ->
        keep_positions =
          messages
          |> tool_result_positions()
          |> Enum.take(-keep_recent_tool_results)
          |> MapSet.new()

        messages
        |> Enum.with_index()
        |> Enum.map_reduce(%{results_cleared: 0, bytes_cleared: 0}, fn {message, message_index},
                                                                       acc ->
          if message_index >= first_old and message_index <= last_old do
            clear_tool_results_in_message(message, message_index, keep_positions, acc)
          else
            {message, acc}
          end
        end)
    end
  end

  defp old_message_bounds([_first | rest], keep_recent_tokens) do
    {previous_summary, tail} = Summary.pop_existing(rest)
    offset = if previous_summary, do: 2, else: 1

    if tail == [] do
      nil
    else
      cut_index = Summary.find_cut_point(tail, keep_recent_tokens)
      if cut_index > 0, do: {offset, offset + cut_index - 1}, else: nil
    end
  end

  defp old_message_bounds(_, _keep_recent_tokens), do: nil

  defp tool_result_positions(messages) do
    for {%Message{content: blocks}, message_index} when is_list(blocks) <-
          Enum.with_index(messages),
        {%{type: type}, block_index} <- Enum.with_index(blocks),
        type in ["tool_result", "server_tool_result"] do
      {message_index, block_index}
    end
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
          if MapSet.member?(keep_positions, {message_index, block_index}) do
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
  # stay together. If it is too large on its own, fit_tool_results/3 shrinks
  # its biggest results afterwards.
  defp fallback_compact(%State{config: %{compaction: %{fallback: :truncate}}}, messages) do
    count = length(messages)
    in_flight_count = count - in_flight_start(messages)
    keep_recent = max(min(@default_keep_recent, max(1, count - 2)), in_flight_count)
    compact_messages(messages, keep_recent: keep_recent)
  end

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
        "on_compaction callback crashed #{Sanitize.exception_header(e, 500)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(stacktrace)}"
      )

      :ok
  catch
    kind, payload ->
      stacktrace = Sanitize.stacktrace(__STACKTRACE__)

      Logger.warning(
        "on_compaction callback error (#{kind}): #{Sanitize.exit_summary(payload)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(stacktrace)}"
      )

      :ok
  end

  defp fire_on_compaction(_, _), do: :ok

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
