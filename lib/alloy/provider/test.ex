defmodule Alloy.Provider.Test do
  @moduledoc """
  A scripted test provider that returns pre-configured responses in order.

  Used for testing agent behavior without making HTTP calls. Start an Agent
  process with a list of responses, then pass its pid in the config.

  ## Usage

      {:ok, pid} = Alloy.Provider.Test.start_link([
        Alloy.Provider.Test.text_response("Hello!"),
        Alloy.Provider.Test.text_response("Goodbye!")
      ])

      config = %{agent_pid: pid}

      {:ok, resp1} = Alloy.Provider.Test.complete([msg], [], config)
      # resp1 contains "Hello!"

      {:ok, resp2} = Alloy.Provider.Test.complete([msg], [], config)
      # resp2 contains "Goodbye!"
  """

  @behaviour Alloy.Provider

  @doc """
  Starts an Agent process holding the list of scripted responses.

  Returns `{:ok, pid}` where the pid should be placed in the config
  as `:agent_pid`.
  """
  @spec start_link([{:ok, Alloy.Provider.completion_response()} | {:error, term()}]) ::
          {:ok, pid()}
  def start_link(responses) when is_list(responses) do
    Agent.start_link(fn -> responses end)
  end

  @doc """
  Pops the next scripted response from the agent.

  Ignores `messages` and `tool_defs` -- they exist only to satisfy the
  behaviour callback. Config must contain `:agent_pid`.

  Returns `{:error, :no_more_responses}` when all responses have been consumed.
  """
  @impl Alloy.Provider
  def complete(_messages, _tool_defs, %{agent_pid: pid}) do
    pop_response(pid)
  end

  @doc """
  Streams the next scripted response, calling `on_chunk` for each character
  of text content. For tool_use responses, returns the response without
  streaming. Consumes from the same script queue as `complete/3`.
  """
  @impl Alloy.Provider
  def stream(_messages, _tool_defs, %{agent_pid: pid} = config, on_chunk)
      when is_function(on_chunk, 1) do
    on_event = Map.get(config, :on_event, fn _ -> :ok end)

    case pop_response(pid) do
      {:ok, %{stop_reason: :end_turn, messages: messages} = response} ->
        # Stream each character of text content
        for msg <- messages,
            text = Alloy.Message.text(msg),
            text != nil,
            char <- String.graphemes(text) do
          on_chunk.(char)
          on_event.({:text_delta, char})
        end

        {:ok, response}

      {:thinking_then_error, thinking_text, error} ->
        # Emit a thinking delta, then return a retryable error.
        # Used to test that chunks_emitted? also tracks on_event emissions.
        on_event.({:thinking_delta, thinking_text})
        {:error, error}

      other ->
        # Tool use or error -- return as-is without streaming
        other
    end
  end

  defp pop_response(pid) do
    result =
      Agent.get_and_update(pid, fn
        [] ->
          {{:error, :no_more_responses}, []}

        [{:with_delay, ms, response} | rest] ->
          {{:delayed, ms, response}, rest}

        [response | rest] ->
          {response, rest}
      end)

    case result do
      {:delayed, ms, response} ->
        Process.sleep(ms)
        response

      other ->
        other
    end
  end

  # --- Helper functions for building scripted responses ---

  @doc """
  Builds a scripted `{:ok, completion_response}` with a simple text reply.
  """
  @spec text_response(String.t()) :: {:ok, Alloy.Provider.completion_response()}
  def text_response(text) when is_binary(text) do
    {:ok,
     %{
       stop_reason: :end_turn,
       messages: [Alloy.Message.assistant(text)],
       usage: %{input_tokens: 10, output_tokens: 5}
     }}
  end

  @doc """
  Builds a scripted `{:ok, completion_response}` with tool_use blocks.
  """
  @spec tool_use_response([Alloy.Message.content_block()]) ::
          {:ok, Alloy.Provider.completion_response()}
  def tool_use_response(tool_calls) when is_list(tool_calls) do
    blocks =
      Enum.map(tool_calls, fn call ->
        Map.put_new(call, :type, "tool_use")
      end)

    {:ok,
     %{
       stop_reason: :tool_use,
       messages: [Alloy.Message.assistant_blocks(blocks)],
       usage: %{input_tokens: 10, output_tokens: 5}
     }}
  end

  @doc """
  Builds a scripted response that sleeps for `delay_ms` milliseconds before
  returning. Useful for testing that callers remain responsive during long
  LLM turns.
  """
  @spec slow_text_response(String.t(), non_neg_integer()) ::
          {:with_delay, non_neg_integer(), {:ok, Alloy.Provider.completion_response()}}
  def slow_text_response(text, delay_ms \\ 200) when is_binary(text) and is_integer(delay_ms) do
    {:with_delay, delay_ms, text_response(text)}
  end

  @doc """
  Builds a scripted `{:error, reason}` response.
  """
  @spec error_response(term()) :: {:error, term()}
  def error_response(reason) do
    {:error, reason}
  end

  @doc """
  Builds a scripted response that emits a thinking delta via `on_event`, then
  returns a retryable error. Used to test that `chunks_emitted?` tracks
  `on_event` emissions so retries don't re-emit thinking deltas.
  """
  @spec thinking_error_response(String.t(), term()) :: {:thinking_then_error, String.t(), term()}
  def thinking_error_response(thinking_text, error_reason) do
    {:thinking_then_error, thinking_text, error_reason}
  end
end
