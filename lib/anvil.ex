defmodule Anvil do
  @moduledoc """
  Model-agnostic agent harness for Elixir.

  Anvil provides the minimal agent loop: send messages to any LLM,
  execute tool calls, loop until done. Zero framework dependencies.

  ## Quick Start

      {:ok, result} = Anvil.run("What is 2+2?",
        provider: {Anvil.Provider.Anthropic, api_key: "sk-ant-..."},
        system_prompt: "You are helpful."
      )
      result.text #=> "4"

  ## With Tools

      {:ok, result} = Anvil.run("Read mix.exs and tell me the version",
        provider: {Anvil.Provider.Anthropic, api_key: "sk-ant-..."},
        tools: [Anvil.Tool.Core.Read],
        max_turns: 10
      )

  ## Continuing a Conversation

      {:ok, result} = Anvil.run("Now edit that file",
        provider: {Anvil.Provider.OpenAI, api_key: "sk-..."},
        tools: [Anvil.Tool.Core.Read, Anvil.Tool.Core.Edit],
        messages: previous_result.messages
      )

  ## Options

  - `:provider` - `{module, config_keyword_list}` or just `module` (required)
  - `:tools` - list of modules implementing `Anvil.Tool` (default: `[]`)
  - `:system_prompt` - system prompt string (default: `nil`)
  - `:messages` - existing conversation history (default: `[]`)
  - `:max_turns` - maximum agent loop iterations (default: `25`)
  - `:max_tokens` - context window budget for compaction (default: `200_000`)
  - `:middleware` - list of `Anvil.Middleware` modules (default: `[]`)
  - `:working_directory` - base path for file tools (default: `"."`)
  - `:context` - arbitrary map passed to tools and middleware (default: `%{}`)
  """

  alias Anvil.Agent.{Config, State, Turn}
  alias Anvil.Message

  @type result :: %{
          text: String.t() | nil,
          messages: [Message.t()],
          usage: Anvil.Usage.t(),
          status: State.status(),
          turns: non_neg_integer(),
          error: term() | nil
        }

  @doc """
  Run the agent loop with a message and options.

  The first argument can be a string (converted to a user message)
  or ignored if `:messages` option provides conversation history.

  Returns `{:ok, result}` on completion or `{:error, result}` on failure.
  """
  @spec run(String.t() | nil, keyword()) :: {:ok, result()} | {:error, result()}
  def run(message \\ nil, opts) do
    config = Config.from_opts(opts)
    messages = build_messages(message, opts)
    state = State.init(config, messages)

    final_state = Turn.run_loop(state)

    result = %{
      text: State.last_assistant_text(final_state),
      messages: final_state.messages,
      usage: final_state.usage,
      status: final_state.status,
      turns: final_state.turn,
      error: final_state.error
    }

    case final_state.status do
      :completed -> {:ok, result}
      :max_turns -> {:ok, result}
      _ -> {:error, result}
    end
  end

  defp build_messages(nil, opts) do
    Keyword.get(opts, :messages, [])
  end

  defp build_messages(text, opts) when is_binary(text) do
    existing = Keyword.get(opts, :messages, [])
    existing ++ [Message.user(text)]
  end
end
