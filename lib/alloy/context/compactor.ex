defmodule Alloy.Context.Compactor do
  @moduledoc """
  Summary-based context compaction.

  When the conversation approaches the configured reserve threshold, Alloy
  preserves the first message, keeps a recent verbatim token window, and
  replaces older context with a structured handoff summary. If summary
  generation fails, Alloy falls back to deterministic truncation.
  """

  require Logger

  alias Alloy.Agent.State
  alias Alloy.Message

  @default_keep_recent 10
  @truncate_length 200

  @summary_prefix "Previous analysis summary (from earlier in this session):"

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

  @doc """
  Prefix used for synthetic handoff summary messages inserted by the compactor.
  """
  @spec summary_prefix() :: String.t()
  def summary_prefix, do: @summary_prefix

  @doc """
  Forces compaction regardless of reserve budget.
  Used when the provider rejects the prompt as too long.
  """
  @spec force_compact(State.t()) :: State.t()
  def force_compact(%State{} = state) do
    compact_messages_in_state(state, State.messages(state))
  end

  @doc """
  Compacts state messages when they exceed `max_tokens - reserve_tokens`.

  Returns `{:compacted, state}` when compaction occurred, or
  `{:unchanged, state}` when already within budget.
  """
  @spec maybe_compact(State.t()) :: {:compacted | :unchanged, State.t()}
  def maybe_compact(%State{} = state) do
    messages = State.messages(state)
    reserve_tokens = state.config.compaction.reserve_tokens

    if within_reserve?(messages, state.config.max_tokens, reserve_tokens) do
      {:unchanged, state}
    else
      {:compacted, compact_messages_in_state(state, messages)}
    end
  end

  # Splits messages into {first, middle, recent} for truncation compaction.
  # The middle slice is what gets compacted; first and recent are preserved.
  defp split_messages(messages, keep_recent) do
    [first | rest] = messages
    rest_len = length(rest)
    recent_count = min(keep_recent, rest_len)
    {middle, recent} = Enum.split(rest, rest_len - recent_count)
    {first, middle, recent}
  end

  defp compact_messages_in_state(%State{} = state, messages) do
    keep_recent_tokens = state.config.compaction.keep_recent_tokens

    case prepare_summary_compaction(messages, keep_recent_tokens) do
      {:ok, prepared} ->
        fire_on_compaction(prepared.messages_to_summarize, state)

        case summarize_compaction(prepared, state) do
          {:ok, summary_text} ->
            compacted = [prepared.first, build_summary_message(summary_text) | prepared.recent]
            %{state | messages: compacted, messages_new: []}

          {:error, reason} ->
            Logger.warning(
              "summary compaction failed, falling back to truncation: #{inspect(reason)}"
            )

            fallback_compact_state(state, messages)
        end

      :noop ->
        fallback_compact_state(state, messages)
    end
  end

  defp fallback_compact_state(%State{} = state, messages) do
    case state.config.compaction.fallback do
      :truncate ->
        msg_count = length(messages)
        keep_recent = min(@default_keep_recent, max(1, msg_count - 2))
        compacted = compact_messages(messages, keep_recent: keep_recent)
        %{state | messages: compacted, messages_new: []}
    end
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

  defp summarize_compaction(prepared, %State{} = state) do
    provider = state.config.provider

    config =
      state.config.provider_config
      |> Map.delete(:provider_state)
      |> Map.delete("provider_state")
      |> Map.put(:system_prompt, @summary_system_prompt)

    prompt = build_summary_prompt(prepared.messages_to_summarize, prepared.previous_summary)

    with {:ok, response} <- provider.complete([Message.user(prompt)], [], config),
         {:ok, summary_text} <- extract_summary_text(response) do
      {:ok, summary_text}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp build_summary_prompt(messages_to_summarize, previous_summary) do
    previous_summary_section =
      case previous_summary do
        nil ->
          ""

        %Message{} = message ->
          "<previous-summary>\n#{summary_body(message)}\n</previous-summary>\n\n"
      end

    """
    #{previous_summary_section}<conversation>
    #{serialize_messages(messages_to_summarize)}
    </conversation>

    #{@summary_prompt}
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
    threshold_index = find_threshold_index(messages, keep_recent_tokens)
    last_index = length(messages) - 1

    user_cut =
      threshold_index..last_index
      |> Enum.find(fn index -> real_user_message?(Enum.at(messages, index)) end)

    assistant_cut =
      threshold_index..last_index
      |> Enum.find(fn index -> assistant_message?(Enum.at(messages, index)) end)

    fallback_cut =
      0..threshold_index
      |> Enum.reverse()
      |> Enum.find(fn index -> valid_cut_message?(Enum.at(messages, index)) end)

    user_cut || assistant_cut || fallback_cut || 0
  end

  defp find_cut_point(_messages, _keep_recent_tokens), do: 0

  defp find_threshold_index(messages, keep_recent_tokens) do
    max_index = length(messages) - 1

    Enum.reduce_while(max_index..0//-1, {0, 0}, fn index,
                                                   {_threshold_index, accumulated_tokens} ->
      accumulated_tokens =
        accumulated_tokens + estimate_message_tokens(Enum.at(messages, index))

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

  defp serialize_messages(messages) do
    messages
    |> Enum.map(&serialize_message/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp serialize_message(%Message{role: role, content: content}) when is_binary(content) do
    "[#{role_label(role)}]\n#{content}"
  end

  defp serialize_message(%Message{role: role, content: blocks}) when is_list(blocks) do
    blocks
    |> Enum.map(&serialize_block(role, &1))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp serialize_block(role, %{type: "text", text: text}) when is_binary(text) do
    "[#{role_label(role)}]\n#{text}"
  end

  defp serialize_block(:assistant, %{type: "thinking", thinking: text}) when is_binary(text) do
    "[Assistant thinking]\n#{text}"
  end

  defp serialize_block(:assistant, %{type: type, name: name, input: input})
       when type in ["tool_use", "server_tool_use"] do
    "[Assistant tool call] #{name}(#{encode_block_data(input)})"
  end

  defp serialize_block(_role, %{type: type, content: content})
       when type in ["tool_result", "server_tool_result"] do
    "[Tool result]\n#{block_content_to_string(content)}"
  end

  defp serialize_block(role, block) do
    "[#{role_label(role)} block #{Map.get(block, :type, "unknown")}]\n#{inspect(block)}"
  end

  defp encode_block_data(data) do
    case Jason.encode(data) do
      {:ok, json} -> json
      {:error, _} -> inspect(data)
    end
  end

  defp block_content_to_string(content) when is_binary(content), do: content
  defp block_content_to_string(content), do: inspect(content)

  defp role_label(:user), do: "User"
  defp role_label(:assistant), do: "Assistant"

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
      Logger.warning(
        "on_compaction callback crashed: #{Exception.message(e)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      :ok
  catch
    kind, payload ->
      Logger.warning(
        "on_compaction callback error (#{kind}): #{inspect(payload)}\n" <>
          "Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      :ok
  end

  defp fire_on_compaction(_, _), do: :ok

  @doc """
  Compacts messages, preserving the first message and the most recent N messages.

  This helper intentionally stays deterministic and provider-free so it can serve
  as the fallback truncation strategy.

  ## Options
    * `:keep_recent` - number of recent messages to preserve (default #{@default_keep_recent})
  """
  @spec compact_messages([Message.t()], keyword()) :: [Message.t()]
  def compact_messages(messages, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    count = length(messages)

    if count <= keep_recent + 1 do
      messages
    else
      {first, middle, recent} = split_messages(messages, keep_recent)
      compacted_middle = Enum.map(middle, &compact_message/1)
      [first | compacted_middle] ++ recent
    end
  end

  defp compact_message(%Message{content: blocks} = msg) when is_list(blocks) do
    compacted_blocks =
      Enum.map(blocks, fn
        %{type: type} = block when type in ["tool_result", "server_tool_result"] ->
          %{block | content: "[compacted]"}

        %{type: "thinking", thinking: text} = block when byte_size(text) > @truncate_length ->
          %{block | thinking: String.slice(text, 0, @truncate_length) <> "..."}

        block ->
          block
      end)

    %{msg | content: compacted_blocks}
  end

  defp compact_message(%Message{role: :assistant, content: text} = msg) when is_binary(text) do
    if String.length(text) > @truncate_length do
      %{msg | content: String.slice(text, 0, @truncate_length) <> "..."}
    else
      msg
    end
  end

  defp compact_message(msg), do: msg

  # --- Token estimation (inlined from TokenCounter) ---
  # Chars/4 heuristic — good enough for budget decisions, not billing.

  # Fixed heuristics for media types. Intentionally conservative rough estimates.
  @image_tokens 1_000
  @audio_tokens 500
  @video_tokens 2_000
  @document_tokens 3_000

  defp estimate_tokens(text) when is_binary(text), do: div(String.length(text), 4)

  defp estimate_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_message_tokens(msg) end)
  end

  defp estimate_message_tokens(%Message{content: content}) when is_binary(content) do
    estimate_tokens(content)
  end

  defp estimate_message_tokens(%Message{content: blocks}) when is_list(blocks) do
    Enum.reduce(blocks, 0, fn block, acc -> acc + estimate_block_tokens(block) end)
  end

  defp estimate_block_tokens(%{type: "text", text: text}) when is_binary(text) do
    estimate_tokens(text)
  end

  defp estimate_block_tokens(%{type: "tool_use", name: name, input: input}) do
    name_tokens = estimate_tokens(to_string(name))

    input_str =
      case Jason.encode(input) do
        {:ok, json} -> json
        {:error, _} -> inspect(input)
      end

    name_tokens + estimate_tokens(input_str)
  end

  defp estimate_block_tokens(%{type: "tool_result", content: content}) when is_binary(content) do
    estimate_tokens(content)
  end

  defp estimate_block_tokens(%{type: "thinking", thinking: text}) when is_binary(text) do
    estimate_tokens(text)
  end

  defp estimate_block_tokens(%{type: "server_tool_use", name: name, input: input}) do
    name_tokens = estimate_tokens(to_string(name))

    input_str =
      case Jason.encode(input) do
        {:ok, json} -> json
        {:error, _} -> inspect(input)
      end

    name_tokens + estimate_tokens(input_str)
  end

  defp estimate_block_tokens(%{type: "server_tool_result", content: content})
       when is_binary(content) do
    estimate_tokens(content)
  end

  defp estimate_block_tokens(%{type: "image"}), do: @image_tokens
  defp estimate_block_tokens(%{type: "audio"}), do: @audio_tokens
  defp estimate_block_tokens(%{type: "video"}), do: @video_tokens
  defp estimate_block_tokens(%{type: "document"}), do: @document_tokens
  defp estimate_block_tokens(_block), do: 0

  defp within_reserve?(messages, max_tokens, reserve_tokens) do
    estimate_tokens(messages) <= max(max_tokens - reserve_tokens, 0)
  end
end
