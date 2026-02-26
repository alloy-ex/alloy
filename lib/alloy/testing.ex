defmodule Alloy.Testing do
  @moduledoc """
  ExUnit helpers for testing agents built with Alloy.

  `use Alloy.Testing` imports convenience functions that eliminate
  boilerplate when writing tests for your agent. All helpers use
  `Alloy.Provider.Test` under the hood — no HTTP calls are made.

  ## Example

      defmodule MyAgent.Test do
        use ExUnit.Case, async: true
        use Alloy.Testing

        test "agent greets the user" do
          result = run_with_responses("Hello", [
            text_response("Hi there!")
          ])

          assert result.status == :completed
          assert last_text(result) == "Hi there!"
        end

        test "agent uses the weather tool" do
          result = run_with_responses("What's the weather?", [
            tool_response("get_weather", %{location: "Sydney"}),
            text_response("It's 22°C in Sydney.")
          ])

          assert_tool_called(result, "get_weather")
          assert last_text(result) =~ "Sydney"
        end
      end
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Alloy.Testing
    end
  end

  alias Alloy.Agent.{Config, State, Turn}
  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider

  @doc """
  Run the agent turn loop with scripted provider responses.

  Takes a user prompt and a list of scripted responses (built with
  `text_response/1`, `tool_response/2`, or `error_response/1`).

  Returns the final `Alloy.Agent.State` struct.

  ## Options

  - `:tools` - list of tool modules (default: `[Alloy.Test.EchoTool]`)
  - `:system_prompt` - system prompt string
  - `:max_turns` - maximum turns (default: 10)
  - `:middleware` - list of middleware modules
  - `:working_directory` - working directory for tools
  """
  @spec run_with_responses(String.t(), [term()], keyword()) :: State.t()
  def run_with_responses(prompt, responses, opts \\ []) do
    {:ok, pid} = TestProvider.start_link(responses)

    config = %Config{
      provider: TestProvider,
      provider_config: %{agent_pid: pid},
      tools: Keyword.get(opts, :tools, [Alloy.Test.EchoTool]),
      system_prompt: Keyword.get(opts, :system_prompt),
      max_turns: Keyword.get(opts, :max_turns, 10),
      middleware: Keyword.get(opts, :middleware, []),
      working_directory: Keyword.get(opts, :working_directory, ".")
    }

    state = State.init(config, [Message.user(prompt)])
    Turn.run_loop(state)
  end

  @doc """
  Build a scripted text response for the test provider.

  Shortcut for `Alloy.Provider.Test.text_response/1`.
  """
  @spec text_response(String.t()) :: {:ok, map()}
  def text_response(text), do: TestProvider.text_response(text)

  @doc """
  Build a scripted tool use response for the test provider.

  Takes a tool name and input map, generates a tool call block with
  a unique ID.
  """
  @spec tool_response(String.t(), map()) :: {:ok, map()}
  def tool_response(tool_name, input) do
    call_id = "call_#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"

    TestProvider.tool_use_response([
      %{type: "tool_use", id: call_id, name: tool_name, input: input}
    ])
  end

  @doc """
  Build a scripted error response for the test provider.

  Shortcut for `Alloy.Provider.Test.error_response/1`.
  """
  @spec error_response(term()) :: {:error, term()}
  def error_response(reason), do: TestProvider.error_response(reason)

  @doc """
  Extract the text content from the last assistant message in a result.

  Returns `nil` if there are no assistant messages.
  """
  @spec last_text(State.t() | map()) :: String.t() | nil
  def last_text(%{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant} = msg -> Message.text(msg)
      _ -> nil
    end)
  end

  def last_text(_), do: nil

  @doc """
  Extract all tool call blocks from the conversation.

  Returns a list of maps with `:name`, `:id`, and `:input` keys.
  """
  @spec tool_calls(State.t() | map()) :: [map()]
  def tool_calls(%{messages: messages}) do
    Enum.flat_map(messages, fn
      %Message{role: :assistant, content: blocks} when is_list(blocks) ->
        Enum.filter(blocks, &(&1[:type] == "tool_use"))

      _ ->
        []
    end)
  end

  def tool_calls(_), do: []

  @doc """
  Assert that a tool was called during the conversation.

  Optionally match against the tool's input with a partial map.

  ## Examples

      assert_tool_called(result, "bash")
      assert_tool_called(result, "read", %{"file_path" => "mix.exs"})
  """
  defmacro assert_tool_called(result, tool_name) do
    quote do
      calls = Alloy.Testing.tool_calls(unquote(result))
      names = Enum.map(calls, & &1.name)

      assert unquote(tool_name) in names,
             "Expected tool #{inspect(unquote(tool_name))} to be called, " <>
               "but only these tools were called: #{inspect(names)}"
    end
  end

  defmacro assert_tool_called(result, tool_name, input_match) do
    quote do
      calls = Alloy.Testing.tool_calls(unquote(result))
      name = unquote(tool_name)
      expected = unquote(input_match)

      matching =
        Enum.filter(calls, fn call ->
          call.name == name &&
            Enum.all?(expected, fn {k, v} ->
              # Match both atom and string keys
              Map.get(call.input, k) == v || Map.get(call.input, to_string(k)) == v ||
                (is_binary(k) && Map.get(call.input, String.to_existing_atom(k)) == v)
            end)
        end)

      assert matching != [],
             "Expected tool #{inspect(name)} to be called with input matching " <>
               "#{inspect(expected)}, but got: #{inspect(Enum.filter(calls, &(&1.name == name)) |> Enum.map(& &1.input))}"
    end
  end

  @doc """
  Assert that a tool was NOT called during the conversation.
  """
  defmacro refute_tool_called(result, tool_name) do
    quote do
      calls = Alloy.Testing.tool_calls(unquote(result))
      names = Enum.map(calls, & &1.name)

      refute unquote(tool_name) in names,
             "Expected tool #{inspect(unquote(tool_name))} NOT to be called, but it was"
    end
  end
end
