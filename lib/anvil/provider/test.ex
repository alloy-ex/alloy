defmodule Anvil.Provider.Test do
  @moduledoc """
  A scripted test provider that returns pre-configured responses in order.

  Used for testing agent behavior without making HTTP calls. Start an Agent
  process with a list of responses, then pass its pid in the config.

  ## Usage

      {:ok, pid} = Anvil.Provider.Test.start_link([
        Anvil.Provider.Test.text_response("Hello!"),
        Anvil.Provider.Test.text_response("Goodbye!")
      ])

      config = %{agent_pid: pid}

      {:ok, resp1} = Anvil.Provider.Test.complete([msg], [], config)
      # resp1 contains "Hello!"

      {:ok, resp2} = Anvil.Provider.Test.complete([msg], [], config)
      # resp2 contains "Goodbye!"
  """

  @behaviour Anvil.Provider

  @doc """
  Starts an Agent process holding the list of scripted responses.

  Returns `{:ok, pid}` where the pid should be placed in the config
  as `:agent_pid`.
  """
  @spec start_link([{:ok, Anvil.Provider.completion_response()} | {:error, term()}]) ::
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
  @impl Anvil.Provider
  def complete(_messages, _tool_defs, %{agent_pid: pid}) do
    Agent.get_and_update(pid, fn
      [] -> {{:error, :no_more_responses}, []}
      [response | rest] -> {response, rest}
    end)
  end

  # --- Helper functions for building scripted responses ---

  @doc """
  Builds a scripted `{:ok, completion_response}` with a simple text reply.
  """
  @spec text_response(String.t()) :: {:ok, Anvil.Provider.completion_response()}
  def text_response(text) when is_binary(text) do
    {:ok,
     %{
       stop_reason: :end_turn,
       messages: [Anvil.Message.assistant(text)],
       usage: %{input_tokens: 10, output_tokens: 5}
     }}
  end

  @doc """
  Builds a scripted `{:ok, completion_response}` with tool_use blocks.
  """
  @spec tool_use_response([Anvil.Message.content_block()]) ::
          {:ok, Anvil.Provider.completion_response()}
  def tool_use_response(tool_calls) when is_list(tool_calls) do
    blocks =
      Enum.map(tool_calls, fn call ->
        Map.put_new(call, :type, "tool_use")
      end)

    {:ok,
     %{
       stop_reason: :tool_use,
       messages: [Anvil.Message.assistant_blocks(blocks)],
       usage: %{input_tokens: 10, output_tokens: 5}
     }}
  end

  @doc """
  Builds a scripted `{:error, reason}` response.
  """
  @spec error_response(term()) :: {:error, term()}
  def error_response(reason) do
    {:error, reason}
  end
end
