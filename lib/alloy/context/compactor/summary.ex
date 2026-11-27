defmodule Alloy.Context.Compactor.Summary do
  @moduledoc false
  # Summary compaction prompts, provider-config sanitization, cut-point
  # selection, and summary request execution.

  alias Alloy.Agent.State
  alias Alloy.Context.Compactor.Estimator
  alias Alloy.Internal.Deadline
  alias Alloy.Message
  alias Alloy.Provider.Retry

  @type prepared :: %{
          first: Message.t(),
          previous_summary: Message.t() | nil,
          messages_to_summarize: [Message.t()],
          recent: [Message.t()]
        }

  @summary_prefix "Previous analysis summary (from earlier in this session):"

  # Provider config keys that tie requests to session continuity, force tool
  # selection, or enable server-side/built-in tools are stripped from compaction
  # summary requests (primary and fallbacks). Privacy settings such as `:store`
  # and `:extra_body["store"]` are preserved.
  @summary_stripped_provider_keys Enum.flat_map(
                                    [
                                      :provider_state,
                                      :persist_session,
                                      :previous_response_id,
                                      :tool_choice,
                                      :parallel_tool_calls,
                                      :built_in_tools,
                                      :web_search,
                                      :x_search,
                                      :server_tools,
                                      :code_execution,
                                      :cache,
                                      :tool_config,
                                      :google_search,
                                      :url_context,
                                      :cached_content,
                                      :prompt_cache_key,
                                      :prompt_cache_retention,
                                      :reasoning,
                                      :reasoning_effort
                                    ],
                                    &[&1, Atom.to_string(&1)]
                                  )

  # extra_body keys that alter thinking, tools, context editing, or output
  # shape are incompatible with plain text summary generation. Other caller
  # keys (for example `"store" => false` for zero data retention) are kept.
  @summary_stripped_extra_body_keys Enum.flat_map(
                                      [
                                        :thinking,
                                        :reasoning,
                                        :reasoning_effort,
                                        :tools,
                                        :tool_choice,
                                        :tool_config,
                                        :toolConfig,
                                        :context_management,
                                        :output_config,
                                        :response_format,
                                        :text,
                                        :previous_response_id,
                                        :cachedContent,
                                        :cached_content,
                                        :prompt_cache_key,
                                        :prompt_cache_retention
                                      ],
                                      &[&1, Atom.to_string(&1)]
                                    )

  # Gemini generationConfig keys that force structured output or thinking
  # interfere with plain-text handoff summaries.
  @summary_stripped_generation_config_keys Enum.flat_map(
                                             [
                                               :responseSchema,
                                               :response_schema,
                                               :responseJsonSchema,
                                               :response_json_schema,
                                               :responseMimeType,
                                               :response_mime_type,
                                               :thinkingConfig,
                                               :thinking_config
                                             ],
                                             &[&1, Atom.to_string(&1)]
                                           )

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

  # Default system prompt used when requesting a handoff summary.
  @spec default_system_prompt() :: String.t()
  def default_system_prompt, do: @summary_system_prompt

  # Default user prompt instructions appended after the serialized conversation.
  @spec default_prompt() :: String.t()
  def default_prompt, do: @summary_prompt

  # Prefix identifying synthetic handoff summary messages in the transcript.
  @spec prefix() :: String.t()
  def prefix, do: @summary_prefix

  # Splits a message list into first message, optional previous summary,
  # messages to summarize, and recent messages to preserve verbatim.
  @spec prepare([Message.t()], non_neg_integer()) :: {:ok, prepared()} | :noop
  def prepare([first | rest], keep_recent_tokens) do
    {previous_summary, tail} = pop_existing(rest)

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

  def prepare(_messages, _keep_recent_tokens), do: :noop

  # Executes the summary provider call through Alloy.Provider.Retry and returns
  # `{result, usage}` so summary usage is accounted for even if extraction fails.
  @spec summarize(prepared(), State.t(), keyword()) ::
          {{:ok, String.t()} | {:error, term()}, map()}
  def summarize(prepared, %State{} = state, opts) do
    opt_deadline = Keyword.get(opts, :deadline)
    hard_deadline = Deadline.min(opt_deadline, state.run_deadline)

    default_deadline =
      case state.config.timeout_ms do
        :infinity -> nil
        timeout_ms -> System.monotonic_time(:millisecond) + timeout_ms
      end

    deadline =
      (Deadline.min(opt_deadline, state.deadline) || default_deadline)
      |> Deadline.min(hard_deadline)

    config =
      state.config.provider_config
      |> sanitize_provider_config()
      |> Map.put(
        :system_prompt,
        Map.get(state.config.compaction, :summary_system_prompt, @summary_system_prompt)
      )
      |> then(fn cfg ->
        if is_integer(hard_deadline),
          do: Map.put(cfg, :alloy_request_deadline, hard_deadline),
          else: cfg
      end)
      |> then(fn cfg ->
        if state.config.cancel_token,
          do: Map.put(cfg, :alloy_cancel_token, state.config.cancel_token),
          else: cfg
      end)

    prompt =
      build_prompt(
        prepared.messages_to_summarize,
        prepared.previous_summary,
        Map.get(state.config.compaction, :summary_prompt, @summary_prompt)
      )

    sanitized_fallbacks =
      Enum.map(state.config.fallback_providers, fn {fb_provider, fb_config} ->
        {fb_provider, sanitize_provider_config(fb_config)}
      end)

    # The summary goes through Retry like any turn request, so it gets the
    # same retries, sanitized fallback providers and receive timeout, bounded
    # by the caller's deadline.
    summary_state = %{
      state
      | config: %{state.config | fallback_providers: sanitized_fallbacks, reasoning: nil},
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

  # Builds a synthetic user message carrying a handoff summary.
  @spec build_message(String.t()) :: Message.t()
  def build_message(summary_text) do
    %Message{role: :user, content: "#{@summary_prefix}\n#{String.trim(summary_text)}"}
  end

  # Returns true when the message is a previously generated handoff summary.
  @spec summary_message?(term()) :: boolean()
  def summary_message?(%Message{role: :user, content: content}) when is_binary(content) do
    String.starts_with?(content, @summary_prefix)
  end

  def summary_message?(_message), do: false

  # Pops a leading summary message if one is present.
  @spec pop_existing([Message.t()]) :: {Message.t() | nil, [Message.t()]}
  def pop_existing([message | rest]) do
    if summary_message?(message), do: {message, rest}, else: {nil, [message | rest]}
  end

  def pop_existing([]), do: {nil, []}

  # Finds the index in `messages` where the kept recent window begins, never
  # cutting inside a tool round.
  @spec find_cut_point([Message.t()], non_neg_integer()) :: non_neg_integer()
  def find_cut_point(messages, keep_recent_tokens) when is_list(messages) and messages != [] do
    indexed = List.to_tuple(messages)
    last_index = tuple_size(indexed) - 1
    threshold_index = find_threshold_index(indexed, last_index, keep_recent_tokens)

    Enum.find(threshold_index..last_index, fn index ->
      real_user_message?(elem(indexed, index))
    end) ||
      Enum.find(threshold_index..last_index, fn index ->
        assistant_message?(elem(indexed, index))
      end) ||
      Enum.find(threshold_index..0//-1, fn index ->
        valid_cut_message?(elem(indexed, index))
      end) ||
      0
  end

  def find_cut_point(_messages, _keep_recent_tokens), do: 0

  # Returns true for user messages that are neither tool results nor summaries.
  @spec real_user_message?(term()) :: boolean()
  def real_user_message?(%Message{role: :user} = message) do
    not tool_result_message?(message) and not summary_message?(message)
  end

  def real_user_message?(_message), do: false

  # Returns true when a user message contains tool result blocks.
  @spec tool_result_message?(term()) :: boolean()
  def tool_result_message?(%Message{role: :user, content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_result", "server_tool_result"] -> true
      _ -> false
    end)
  end

  def tool_result_message?(_message), do: false

  defp sanitize_provider_config(provider_config) when is_map(provider_config) do
    provider_config
    |> Map.drop(@summary_stripped_provider_keys)
    |> sanitize_generation_config_keys([:generation_config, "generation_config"])
    |> sanitize_extra_body_key(:extra_body)
    |> sanitize_extra_body_key("extra_body")
  end

  defp sanitize_extra_body_key(config, key) do
    case Map.get(config, key) do
      extra when is_map(extra) and not is_struct(extra) ->
        cleaned =
          extra
          |> Map.drop(@summary_stripped_extra_body_keys)
          |> sanitize_generation_config_keys([
            :generationConfig,
            "generationConfig",
            :generation_config,
            "generation_config"
          ])

        if cleaned == %{}, do: Map.delete(config, key), else: Map.put(config, key, cleaned)

      _other ->
        Map.delete(config, key)
    end
  end

  defp sanitize_generation_config_keys(map, keys) do
    Enum.reduce(keys, map, &sanitize_generation_config_key(&2, &1))
  end

  defp sanitize_generation_config_key(map, key) do
    case Map.get(map, key) do
      gen_cfg when is_map(gen_cfg) and not is_struct(gen_cfg) ->
        cleaned = Map.drop(gen_cfg, @summary_stripped_generation_config_keys)
        if cleaned == %{}, do: Map.delete(map, key), else: Map.put(map, key, cleaned)

      gen_cfg when is_list(gen_cfg) ->
        if Keyword.keyword?(gen_cfg) do
          cleaned =
            Enum.reject(gen_cfg, fn {k, _v} -> k in @summary_stripped_generation_config_keys end)

          if cleaned == [], do: Map.delete(map, key), else: Map.put(map, key, cleaned)
        else
          map
        end

      _other ->
        map
    end
  end

  defp build_prompt(messages_to_summarize, previous_summary, summary_prompt) do
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

  defp summary_body(%Message{content: content}) when is_binary(content) do
    content
    |> String.replace_prefix(@summary_prefix, "")
    |> String.trim()
  end

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

  defp assistant_message?(%Message{role: :assistant}), do: true
  defp assistant_message?(_message), do: false

  defp valid_cut_message?(message),
    do: real_user_message?(message) or assistant_message?(message)
end
