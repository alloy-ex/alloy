defmodule Alloy.Context.CompactorTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Context.Compactor
  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider

  defmodule ProbeProvider do
    @behaviour Alloy.Provider

    @impl Alloy.Provider
    def complete(
          messages,
          tool_defs,
          %{summary_response: summary_response, test_pid: test_pid} = config
        ) do
      send(test_pid, {:summary_request, messages, tool_defs, config})

      case summary_response do
        {:ok, text} when is_binary(text) ->
          TestProvider.text_response(text)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_state(messages, opts) do
    provider = Keyword.get(opts, :provider, TestProvider)
    provider_config = Keyword.get(opts, :provider_config, %{})
    max_tokens = Keyword.get(opts, :max_tokens, 200_000)
    compaction = Keyword.get(opts, :compaction, [])
    on_compaction = Keyword.get(opts, :on_compaction)

    config =
      Config.from_opts(
        provider: {provider, provider_config},
        max_tokens: max_tokens,
        compaction: compaction,
        on_compaction: on_compaction
      )

    %State{
      config: config,
      messages: messages,
      messages_new: [],
      provider_state: Keyword.get(opts, :provider_state, %{})
    }
  end

  defp start_scripted_provider(responses) do
    {:ok, pid} = TestProvider.start_link(responses)
    pid
  end

  defp summary_text(label) do
    """
    ## Goal
    #{label} goal

    ## Constraints & Preferences
    - keep exact paths

    ## Progress
    ### Done
    - [x] #{label} done

    ### In Progress
    - [ ] #{label} in progress

    ### Blocked
    - (none)

    ## Key Decisions
    - **#{label} decision**: preserve evidence

    ## Evidence & References
    - /tmp/#{String.downcase(label)}.ex

    ## Next Steps
    1. Continue #{String.downcase(label)}

    ## Critical Context
    - #{label} context
    """
  end

  defp summary_message?(%Message{content: content}) when is_binary(content) do
    String.starts_with?(content, Compactor.summary_prefix())
  end

  defp summary_message?(_message), do: false

  defp tool_result_message?(%Message{role: :user, content: blocks}) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_result", "server_tool_result"] -> true
      _ -> false
    end)
  end

  defp tool_result_message?(_message), do: false

  defp assistant_tool_call_message?(%Message{role: :assistant, content: blocks})
       when is_list(blocks) do
    Enum.any?(blocks, fn
      %{type: type} when type in ["tool_use", "server_tool_use"] -> true
      _ -> false
    end)
  end

  defp assistant_tool_call_message?(_message), do: false

  defp tool_pairs_intact?(messages) do
    Enum.with_index(messages)
    |> Enum.all?(fn
      {%Message{} = message, index} when index > 0 ->
        if tool_result_message?(message) do
          assistant_tool_call_message?(Enum.at(messages, index - 1))
        else
          true
        end

      {%Message{} = message, 0} ->
        not tool_result_message?(message)
    end)
  end

  describe "maybe_compact/1" do
    test "returns state unchanged when within reserve budget" do
      messages = [Message.user("hello"), Message.assistant("hi")]

      state =
        build_state(messages,
          max_tokens: 200,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("unused")}, test_pid: self()}
        )

      assert {:unchanged, ^state} = Compactor.maybe_compact(state)
      refute_received {:summary_request, _, _, _}
    end

    test "invokes the provider summarizer and stores a synthetic summary message" do
      messages = [
        Message.user("original request"),
        Message.assistant(String.duplicate("a", 900)),
        Message.user("middle question"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 25, keep_recent_tokens: 20],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("Alpha")}, test_pid: self()},
          provider_state: %{response_id: "should-not-leak"}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert_received {:summary_request, [%Message{role: :user, content: prompt}], [], config}
      assert prompt =~ "<conversation>"
      assert prompt =~ "## Goal"
      refute Map.has_key?(config, :provider_state)

      assert hd(compacted.messages).content == "original request"
      assert Enum.at(compacted.messages, 1).role == :user
      assert summary_message?(Enum.at(compacted.messages, 1))
      assert Enum.at(compacted.messages, 1).content =~ "Alpha goal"
    end

    test "preserves recent messages intact based on the keep_recent_tokens budget" do
      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("a", 800)),
        Message.user(String.duplicate("b", 400)),
        Message.assistant("recent 1"),
        Message.user("recent 2"),
        Message.assistant("recent 3"),
        Message.user("recent 4"),
        Message.assistant("recent 5")
      ]

      state =
        build_state(messages,
          max_tokens: 260,
          compaction: [reserve_tokens: 25, keep_recent_tokens: 50],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("Recent")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert Enum.take(compacted.messages, -5) == Enum.take(messages, -5)
    end

    test "updates the existing summary instead of duplicating it" do
      provider_pid =
        start_scripted_provider([
          TestProvider.text_response(summary_text("First")),
          TestProvider.text_response(summary_text("Updated"))
        ])

      initial_messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("a", 900)),
        Message.user("recent")
      ]

      state =
        build_state(initial_messages,
          max_tokens: 180,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider: TestProvider,
          provider_config: %{agent_pid: provider_pid}
        )

      {:compacted, first_compaction} = Compactor.maybe_compact(state)

      second_state = %{
        first_compaction
        | messages:
            first_compaction.messages ++
              [Message.assistant(String.duplicate("b", 900)), Message.user("new latest")],
          messages_new: []
      }

      {:compacted, second_compaction} = Compactor.maybe_compact(second_state)

      summary_messages = Enum.filter(second_compaction.messages, &summary_message?/1)

      assert length(summary_messages) == 1
      assert hd(summary_messages).content =~ "Updated goal"
      refute hd(summary_messages).content =~ "First goal"
    end

    test "never leaves a kept tool result without its assistant tool call" do
      big_result = String.duplicate("r", 900)

      messages = [
        Message.user("original"),
        Message.user("inspect the file"),
        Message.assistant_blocks([
          %{type: "tool_use", id: "t1", name: "read_file", input: %{path: "lib/foo.ex"}}
        ]),
        Message.tool_results([
          %{type: "tool_result", tool_use_id: "t1", content: big_result}
        ]),
        Message.assistant("analysis after tool"),
        Message.assistant("latest note")
      ]

      state =
        build_state(messages,
          max_tokens: 260,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 5],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("Tool")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert tool_pairs_intact?(Enum.drop(compacted.messages, 2))
      refute tool_result_message?(Enum.at(compacted.messages, 2))
    end

    test "can compact a large single turn by keeping an assistant suffix verbatim" do
      messages = [
        Message.user("original"),
        Message.user("one big turn"),
        Message.assistant(String.duplicate("a", 900)),
        Message.assistant(String.duplicate("b", 900)),
        Message.assistant("tail that should stay verbatim")
      ]

      state =
        build_state(messages,
          max_tokens: 300,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("Split")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)

      assert summary_message?(Enum.at(compacted.messages, 1))
      assert Enum.at(compacted.messages, 2) == Enum.at(messages, 3)
      assert Enum.at(compacted.messages, 3) == Enum.at(messages, 4)
    end

    test "falls back to truncation when summary generation fails" do
      long_text = String.duplicate("a", 500)

      messages = [
        Message.user("original"),
        Message.assistant(long_text),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 120,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:error, :boom}, test_pid: self()}
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:compacted, compacted} = Compactor.maybe_compact(state)
          compacted_msg = Enum.at(compacted.messages, 1)
          assert String.length(compacted_msg.content) <= 203
          refute Enum.any?(compacted.messages, &summary_message?/1)
        end)

      assert log =~ "summary compaction failed, falling back to truncation"
    end
  end

  describe "on_compaction callback" do
    test "fires callback with messages about to be summarized" do
      test_pid = self()

      callback = fn middle_messages, state ->
        send(test_pid, {:compaction_fired, middle_messages, state})
        :ok
      end

      messages = [
        Message.user("original request"),
        Message.assistant(String.duplicate("x", 1200)),
        Message.user("middle question"),
        Message.assistant("middle answer"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("Callback")}, test_pid: self()},
          on_compaction: callback
        )

      {:compacted, _compacted} = Compactor.maybe_compact(state)

      assert_received {:compaction_fired, middle_messages, received_state}
      assert middle_messages != []
      assert %State{} = received_state
    end

    test "does not fire callback when within budget" do
      test_pid = self()

      callback = fn _middle, _state ->
        send(test_pid, :should_not_fire)
        :ok
      end

      messages = [Message.user("hi"), Message.assistant("hello")]

      state =
        build_state(messages,
          max_tokens: 200,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("unused")}, test_pid: self()},
          on_compaction: callback
        )

      {:unchanged, _result} = Compactor.maybe_compact(state)

      refute_received :should_not_fire
    end

    test "compaction still works when on_compaction is nil" do
      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("x", 1200)),
        Message.user("middle"),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("Nil")}, test_pid: self()}
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)
      assert %State{} = compacted
      assert Enum.any?(compacted.messages, &summary_message?/1)
    end

    test "compaction proceeds even when on_compaction crashes" do
      callback = fn _middle, _state ->
        raise "Boom! Callback crashed!"
      end

      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("x", 1200)),
        Message.user("middle"),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("Crash")}, test_pid: self()},
          on_compaction: callback
        )

      {:compacted, compacted} = Compactor.maybe_compact(state)
      assert %State{} = compacted
      assert Enum.any?(compacted.messages, &summary_message?/1)
    end

    test "logs stacktrace when on_compaction raises" do
      callback = fn _middle, _state ->
        raise "Boom! Callback crashed!"
      end

      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("x", 1200)),
        Message.user("middle"),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("Raise")}, test_pid: self()},
          on_compaction: callback
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:compacted, _} = Compactor.maybe_compact(state)
        end)

      assert log =~ "on_compaction callback crashed"
      assert log =~ "Stacktrace"
    end

    test "logs stacktrace when on_compaction throws" do
      callback = fn _middle, _state ->
        throw(:kaboom)
      end

      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("x", 1200)),
        Message.user("middle"),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      state =
        build_state(messages,
          max_tokens: 250,
          compaction: [reserve_tokens: 20, keep_recent_tokens: 20],
          provider: ProbeProvider,
          provider_config: %{summary_response: {:ok, summary_text("Throw")}, test_pid: self()},
          on_compaction: callback
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:compacted, _} = Compactor.maybe_compact(state)
        end)

      assert log =~ "on_compaction callback error"
      assert log =~ "Stacktrace"
    end
  end

  describe "Config parses on_compaction" do
    test "from_opts accepts on_compaction function" do
      callback = fn _msgs, _state -> :ok end

      config =
        Config.from_opts(
          provider: Alloy.Provider.Test,
          on_compaction: callback
        )

      assert config.on_compaction == callback
    end

    test "from_opts defaults on_compaction to nil" do
      config = Config.from_opts(provider: Alloy.Provider.Test)

      assert config.on_compaction == nil
    end
  end

  describe "compact_messages/2" do
    test "preserves first message" do
      messages = [
        Message.user("original request"),
        Message.assistant(String.duplicate("a", 1000)),
        Message.user("middle message"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      compacted = Compactor.compact_messages(messages, keep_recent: 2)

      assert hd(compacted).content == "original request"
    end

    test "preserves recent messages intact" do
      messages = [
        Message.user("original"),
        Message.assistant(String.duplicate("a", 1000)),
        Message.user("middle"),
        Message.assistant("recent reply"),
        Message.user("latest")
      ]

      compacted = Compactor.compact_messages(messages, keep_recent: 2)

      last_two = Enum.take(compacted, -2)
      assert Enum.at(last_two, 0).content == "recent reply"
      assert Enum.at(last_two, 1).content == "latest"
    end

    test "compacts tool_result blocks to [compacted]" do
      tool_content = String.duplicate("r", 500)

      messages = [
        Message.user("original"),
        Message.tool_results([
          %{type: "tool_result", tool_use_id: "t1", content: tool_content}
        ]),
        Message.assistant("ok"),
        Message.user("latest")
      ]

      compacted = Compactor.compact_messages(messages, keep_recent: 2)

      compacted_msg = Enum.at(compacted, 1)
      [block] = compacted_msg.content
      assert block.content == "[compacted]"
    end

    test "truncates old assistant text messages" do
      long_text = String.duplicate("a", 500)

      messages = [
        Message.user("original"),
        Message.assistant(long_text),
        Message.assistant("recent"),
        Message.user("latest")
      ]

      compacted = Compactor.compact_messages(messages, keep_recent: 2)

      compacted_msg = Enum.at(compacted, 1)
      assert String.length(compacted_msg.content) <= 203
    end

    test "handles all messages within keep_recent window" do
      messages = [
        Message.user("hello"),
        Message.assistant("hi")
      ]

      compacted = Compactor.compact_messages(messages, keep_recent: 10)
      assert compacted == messages
    end
  end
end
