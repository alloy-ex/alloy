defmodule Alloy.LoopControlsTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider
  alias Alloy.Tool.Executor

  defmodule Edit do
    @behaviour Alloy.Middleware
    def call(:before_tool_call, state) do
      call = state.config.context.current_tool_call
      {:edit, %{call | input: %{"value" => 2}}}
    end

    def call(_, state), do: state
  end

  defmodule Guard do
    @behaviour Alloy.Middleware
    def call(:before_tool_call, state) do
      send(state.config.context.owner, {:checked, state.config.context.current_tool_call.input})
      {:block, "denied"}
    end

    def call(_, state), do: state
  end

  defmodule Redact do
    @behaviour Alloy.Middleware
    def call(:after_tool_call, state) do
      result = state.config.context.current_tool_result
      {:result, %{result | content: "redacted", data: %{safe: true}}}
    end

    def call(_, state), do: state
  end

  defmodule Prepare do
    @behaviour Alloy.Middleware
    def call(:before_completion, state) do
      State.prepare(state, tools: state.config.context.next_tools, system_prompt: "prepared")
    end

    def call(_, state), do: state
  end

  defmodule Hooks do
    @behaviour Alloy.Middleware
    def call(hook, state) do
      case state.config.context[:hooks] do
        %{^hook => fun} -> fun.(state)
        _ -> state
      end
    end
  end

  defmodule RecordingProvider do
    @behaviour Alloy.Provider
    def complete(messages, tools, config) do
      send(config.owner, {:request, messages, tools, config})
      TestProvider.complete(messages, tools, config)
    end
  end

  defp tool(opts \\ []) do
    owner = self()

    Alloy.Tool.inline(
      Keyword.merge(
        [
          name: "submit",
          description: "Submit an answer",
          input_schema: %{
            type: "object",
            properties: %{value: %{type: "integer", minimum: 1}},
            required: ["value"],
            additionalProperties: false
          },
          execute: fn input, _ ->
            send(owner, {:executed, input})
            {:ok, "answer", %{value: input["value"]}}
          end
        ],
        opts
      )
    )
  end

  defp call(input \\ %{"value" => 1}, id \\ "c1"),
    do: %{id: id, name: "submit", input: input}

  defp state(opts) do
    opts
    |> Keyword.put_new(:provider, TestProvider)
    |> Keyword.put_new(:context, %{owner: self()})
    |> Config.from_opts()
    |> State.init()
  end

  test "edited arguments reach later guards and blocked tools never run" do
    state = state(tools: [tool()], middleware: [Edit, Guard])
    assert {:ok, message, _} = Executor.execute_all([call()], state.tool_fns, state, [])
    assert_receive {:checked, %{"value" => 2}}
    assert [%{is_error: true}] = message.content
    refute_receive {:executed, _}
  end

  test "per-tool result redaction precedes transcript and metadata publication" do
    state = state(tools: [tool()], middleware: [Redact])
    assert {:ok, message, [meta]} = Executor.execute_all([call()], state.tool_fns, state, [])
    assert [%{content: "redacted"}] = message.content
    assert meta.structured_data == %{safe: true}
  end

  @tag :ex_json_schema
  test "schema validation rejects invalid types without invoking the tool" do
    state = state(tools: [tool()], tool_validation: :schema)

    assert {:ok, message, _} =
             Executor.execute_all([call(%{"value" => "1"})], state.tool_fns, state, [])

    assert [%{is_error: true, content: error}] = message.content
    assert error =~ "value"
    refute_receive {:executed, _}
  end

  @tag :ex_json_schema
  test "schema cache drops removed or disabled tools" do
    alias Alloy.Tool.Validation
    tools = %{"submit" => tool(), "other" => tool(name: "other")}
    {_, cache} = Validation.prepare(tools, :schema, %{})
    {remaining, cache} = Validation.prepare(Map.take(tools, ["submit"]), :schema, cache)
    assert Map.keys(remaining) == ["submit"]
    assert Map.keys(cache) == ["submit"]
    assert {%{}, %{}} = Validation.prepare(tools, :required, cache)
  end

  @tag :ex_json_schema
  test "schema changes under the same name invalidate cached validation" do
    alias Alloy.Tool.Validation
    original = tool()
    {_, cache} = Validation.prepare(%{"submit" => original}, :schema, %{})

    changed = %{
      original
      | input_schema: put_in(original.input_schema, [:properties, :value, :minimum], 3)
    }

    {schemas, _} = Validation.prepare(%{"submit" => changed}, :schema, cache)
    assert {:error, _, nil} = Validation.check(%{"value" => 1}, "submit", schemas)
    assert :ok = Validation.check(%{"value" => 3}, "submit", schemas)

    remote = %{original | input_schema: %{"$ref" => "https://example.invalid/schema"}}

    assert_raise ArgumentError, ~r/local/, fn ->
      Validation.prepare(%{"submit" => remote}, :schema, cache)
    end

    ambiguous = %{original | input_schema: %{"type" => "string", type: "object"}}

    assert_raise Jason.EncodeError, fn ->
      Validation.prepare(%{"submit" => ambiguous}, :schema, cache)
    end
  end

  @tag :ex_json_schema
  test "prepared tools invalidate the live loop cache without leaking it into results" do
    owner = self()
    original = tool()

    changed = %{
      original
      | input_schema: put_in(original.input_schema, [:properties, :value, :minimum], 3)
    }

    prepare = fn state ->
      if state.turn == 1 do
        send(owner, {:cached_names, Map.keys(state.tool_schema_cache)})
        State.prepare(state, tools: [changed])
      else
        state
      end
    end

    {:ok, provider} =
      TestProvider.start_link([
        TestProvider.tool_use_response([call()]),
        TestProvider.tool_use_response([call(%{"value" => 1}, "c2")]),
        TestProvider.text_response("done")
      ])

    assert {:ok, result} =
             Alloy.run("go",
               provider: {TestProvider, agent_pid: provider},
               tools: [original],
               tool_validation: :schema,
               middleware: [Hooks],
               context: %{hooks: %{before_completion: prepare}}
             )

    assert_receive {:cached_names, ["submit"]}
    assert_receive {:executed, %{"value" => 1}}
    refute_receive {:executed, _}
    assert [%{error: nil}, %{error: error}] = result.tool_calls
    assert is_binary(error)
    refute Map.has_key?(result.metadata, :tool_schema_cache)
    refute Map.has_key?(result.metadata[:run] || %{}, :tool_schema_cache)
  end

  test "default validation retains compatibility with loose tools" do
    state = state(tools: [tool()])

    assert {:ok, _, _} =
             Executor.execute_all([call(%{"value" => "1"})], state.tool_fns, state, [])

    assert_receive {:executed, %{"value" => "1"}}
  end

  @tag :ex_json_schema
  test "schema validation checks bounds, extra properties, nested schemas, and local references" do
    nested =
      tool(
        input_schema: %{
          type: "object",
          required: ["value"],
          additionalProperties: false,
          properties: %{value: %{"$ref" => "#/definitions/values"}},
          definitions: %{
            values: %{type: "array", minItems: 1, items: %{type: "integer", minimum: 1}}
          }
        }
      )

    state = state(tools: [nested], tool_validation: :schema)

    for input <- [
          %{"value" => []},
          %{"value" => [0]},
          %{"value" => ["1"]},
          %{"value" => [1], "extra" => true}
        ] do
      assert {:ok, %{content: [%{is_error: true}]}, _} =
               Executor.execute_all([call(input)], state.tool_fns, state, [])
    end

    refute_receive {:executed, _}

    assert {:ok, _, _} =
             Executor.execute_all([call(%{"value" => [1]})], state.tool_fns, state, [])

    assert_receive {:executed, %{"value" => [1]}}
  end

  @tag :ex_json_schema
  test "schema validation runs on the final middleware-edited arguments" do
    state = state(tools: [tool()], middleware: [Edit], tool_validation: :schema)

    assert {:ok, _, _} =
             Executor.execute_all([call(%{"value" => "invalid"})], state.tool_fns, state, [])

    assert_receive {:executed, %{"value" => 2}}
  end

  @tag :ex_json_schema
  test "schema validation rejects ambiguous atom and string keys before side effects" do
    state = state(tools: [tool()], tool_validation: :schema)
    input = %{"value" => 1, :value => "invalid"}

    assert {:ok, %{content: [%{is_error: true, content: error}]}, _} =
             Executor.execute_all([call(input)], state.tool_fns, state, [])

    assert error =~ "duplicate key"
    refute_receive {:executed, _}
  end

  @tag :ex_json_schema
  test "remote schema references are rejected before tool execution" do
    state =
      state(
        tools: [tool(input_schema: %{"$ref" => "https://example.invalid/schema"})],
        tool_validation: :schema
      )

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Executor.execute_all([call()], state.tool_fns, state, [])
    end

    refute_receive {:executed, _}
  end

  @tag :ex_json_schema
  test "remote schema references fail before the first provider request" do
    owner = self()
    {:ok, provider} = TestProvider.start_link([TestProvider.tool_use_response([call()])])

    assert_raise ArgumentError, ~r/local \$ref/, fn ->
      Alloy.run("go",
        provider: {RecordingProvider, owner: owner, agent_pid: provider},
        tools: [tool(input_schema: %{"$ref" => "https://example.invalid/schema"})],
        tool_validation: :schema
      )
    end

    refute_receive {:request, _, _, _}
  end

  @tag :ex_json_schema
  test "tool properties literally named $ref are accepted by local_refs check" do
    ref_prop_tool =
      tool(
        input_schema: %{
          type: "object",
          properties: %{
            "$ref" => %{type: "string"}
          },
          required: ["$ref"]
        }
      )

    state = state(tools: [ref_prop_tool], tool_validation: :schema)

    assert {:ok, %{content: [block]}, _} =
             Executor.execute_all(
               [call(%{"$ref" => "https://example.invalid/data"})],
               state.tool_fns,
               state,
               []
             )

    refute Map.get(block, :is_error, false)

    assert_receive {:executed, %{"$ref" => "https://example.invalid/data"}}
  end

  @tag :ex_json_schema
  test "schema validation refreshes when :after_tool_request swaps tools" do
    original = tool()

    stricter = %{
      original
      | input_schema: put_in(original.input_schema, [:properties, :value, :type], "string")
    }

    swap = fn state -> State.prepare(state, tools: [stricter]) end

    {:ok, provider} =
      TestProvider.start_link([
        TestProvider.tool_use_response([call(%{"value" => 1})]),
        TestProvider.text_response("done")
      ])

    assert {:ok, result} =
             Alloy.run("go",
               provider: {TestProvider, agent_pid: provider},
               tools: [original],
               tool_validation: :schema,
               middleware: [Hooks],
               context: %{hooks: %{after_tool_request: swap}}
             )

    refute_receive {:executed, _}
    assert [%{error: error}] = result.tool_calls
    assert is_binary(error)
    assert error =~ "value"
  end

  test "result replacements cannot turn failed execution into success" do
    rewrite = fn state ->
      {:result, %{state.config.context.current_tool_result | is_error: false}}
    end

    state =
      state(
        tools: [tool(execute: fn _, _ -> {:error, "failed"} end)],
        middleware: [Hooks],
        context: %{hooks: %{after_tool_call: rewrite}}
      )

    assert_raise ArgumentError, ~r/unchanged is_error/, fn ->
      Executor.execute_all([call()], state.tool_fns, state, [])
    end
  end

  test "result hooks redact errors before tool-end events and preserve failure status" do
    owner = self()

    state =
      state(tools: [tool(execute: fn _, _ -> {:error, "private"} end)], middleware: [Redact])

    assert {:ok, %{content: [%{content: "redacted", is_error: true}]}, [meta]} =
             Executor.execute_all([call()], state.tool_fns, state, on_event: &send(owner, &1))

    assert meta.error == "redacted"
    assert_receive {:tool_end, %{error: "redacted"}}
  end

  test "result hooks redact blocked calls without executing the tool" do
    state = state(tools: [tool()], middleware: [Guard, Redact])

    assert {:ok, %{content: [%{content: "redacted", is_error: true}]}, _} =
             Executor.execute_all([call()], state.tool_fns, state, [])

    refute_receive {:executed, _}
  end

  test "replacement output remains bounded" do
    state = state(tools: [tool(max_result_chars: 2)], middleware: [Redact])

    assert {:ok, %{content: [%{content: content}]}, _} =
             Executor.execute_all([call()], state.tool_fns, state, [])

    assert content =~ "truncated"
    refute content == "redacted"
  end

  test "tool result hook failure cancels remaining workers even when the caller catches it" do
    owner = self()

    blocked =
      tool(
        execute: fn _, _ ->
          send(owner, {:worker, self()})

          receive do
            :release -> {:ok, "private"}
          end
        end
      )

    state =
      state(
        tools: [blocked],
        tool_concurrency: 2,
        middleware: [Hooks],
        context: %{hooks: %{after_tool_call: fn _ -> raise "redaction failed" end}}
      )

    task =
      Task.async(fn ->
        try do
          Executor.execute_all([call(), call(%{"value" => 2}, "c2")], state.tool_fns, state, [])
        rescue
          RuntimeError -> send(owner, :caught)
        end

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:worker, first}
    assert_receive {:worker, second}
    ref = Process.monitor(second)
    send(first, :release)
    assert_receive :caught
    assert_receive {:DOWN, ^ref, :process, ^second, _}
    assert Process.alive?(task.pid)
    send(task.pid, :finish)
    assert :ok = Task.await(task)
  end

  test "result hooks see actual unknown-tool failures" do
    state = state(tools: [], middleware: [Redact])

    assert {:ok, %{content: [%{content: "redacted", is_error: true}]}, _} =
             Executor.execute_all([call()], state.tool_fns, state, [])
  end

  test "a successful selected tool completes without another provider request" do
    {:ok, provider} = TestProvider.start_link([TestProvider.tool_use_response([call()])])

    assert {:ok, result} =
             Alloy.run("answer",
               provider: {TestProvider, agent_pid: provider},
               tools: [tool()],
               stop_after_tool: "submit"
             )

    assert result.status == :completed
    assert result.turns == 1
    assert result.text == "answer"
    assert result.metadata.final_tool.structured_data == %{value: 1}
    assert List.last(result.messages).role == :user
  end

  test "a failed selected tool does not complete early" do
    {:ok, provider} =
      TestProvider.start_link([
        TestProvider.tool_use_response([call()]),
        TestProvider.text_response("recovered")
      ])

    assert {:ok, result} =
             Alloy.run("answer",
               provider: {TestProvider, agent_pid: provider},
               tools: [tool(execute: fn _, _ -> {:error, "failed"} end)],
               stop_after_tool: "submit"
             )

    assert result.turns == 2
    assert result.text == "recovered"
  end

  test "successful stop settles a mixed round and chooses the first matching result in source order" do
    other = tool(name: "other", execute: fn _, _ -> {:error, "other failed"} end)
    calls = [call(), %{call() | name: "other", id: "c2"}, call(%{"value" => 2}, "c3")]
    {:ok, provider} = TestProvider.start_link([TestProvider.tool_use_response(calls)])

    assert {:ok, result} =
             Alloy.run("answer",
               provider: {TestProvider, agent_pid: provider},
               tools: [tool(), other],
               stop_after_tool: "submit"
             )

    assert result.metadata.final_tool.id == "c1"
    assert length(List.last(result.messages).content) == 3
    assert Enum.at(result.tool_calls, 1).error == "other failed"
  end

  test "a blocked selected tool cannot complete a run" do
    {:ok, provider} =
      TestProvider.start_link([
        TestProvider.tool_use_response([call()]),
        TestProvider.text_response("denied")
      ])

    assert {:ok, result} =
             Alloy.run("answer",
               provider: {TestProvider, agent_pid: provider},
               tools: [tool()],
               middleware: [Guard],
               context: %{owner: self()},
               stop_after_tool: "submit"
             )

    assert result.turns == 2
    refute Map.has_key?(result.metadata, :final_tool)
    refute_receive {:executed, _}
  end

  test "batch middleware can halt before successful tool completion" do
    {:ok, provider} = TestProvider.start_link([TestProvider.tool_use_response([call()])])

    assert {:error, %{status: :halted}} =
             Alloy.run("answer",
               provider: {TestProvider, agent_pid: provider},
               tools: [tool()],
               middleware: [Hooks],
               context: %{hooks: %{after_tool_execution: fn _ -> {:halt, "policy"} end}},
               stop_after_tool: "submit"
             )
  end

  test "early completion respects batch result redaction" do
    redact = fn state ->
      messages =
        List.update_at(state.messages, -1, fn message ->
          %{
            message
            | content: Enum.map(message.content, &Map.put(&1, :content, "batch redacted"))
          }
        end)

      calls = Enum.map(state.tool_calls, &Map.put(&1, :structured_data, %{safe: true}))
      %{state | messages: messages, tool_calls: calls}
    end

    {:ok, provider} = TestProvider.start_link([TestProvider.tool_use_response([call()])])

    assert {:ok, result} =
             Alloy.run("answer",
               provider: {TestProvider, agent_pid: provider},
               tools: [tool()],
               stop_after_tool: "submit",
               middleware: [Hooks],
               context: %{hooks: %{after_tool_execution: redact}}
             )

    assert result.text == "batch redacted"
    assert result.metadata.final_tool.structured_data == %{safe: true}
  end

  test "until_tool remains a prerequisite for successful early completion" do
    finish = tool(name: "finish")

    {:ok, provider} =
      TestProvider.start_link([
        TestProvider.tool_use_response([call()]),
        TestProvider.tool_use_response([%{call() | name: "finish", id: "c2"}]),
        TestProvider.text_response("done")
      ])

    assert {:ok, result} =
             Alloy.run("answer",
               provider: {TestProvider, agent_pid: provider},
               tools: [tool(), finish],
               stop_after_tool: "submit",
               until_tool: "finish"
             )

    assert result.turns == 3
    assert result.text == "done"
  end

  test "streaming early completion returns the tool output without synthesizing assistant deltas" do
    {:ok, provider} = TestProvider.start_link([TestProvider.tool_use_response([call()])])
    owner = self()

    assert {:ok, result} =
             Alloy.stream("answer", &send(owner, {:chunk, &1}),
               provider: {TestProvider, agent_pid: provider},
               tools: [tool()],
               stop_after_tool: "submit"
             )

    assert result.text == "answer"
    refute_receive {:chunk, _}
  end

  test "request preparation updates both advertised and executable tools" do
    {:ok, provider} =
      TestProvider.start_link([
        TestProvider.tool_use_response([call()]),
        TestProvider.text_response("done")
      ])

    assert {:ok, _} =
             Alloy.run("answer",
               provider: {RecordingProvider, agent_pid: provider, owner: self()},
               middleware: [Prepare],
               context: %{next_tools: [tool()]}
             )

    assert_receive {:request, _, [%{name: "submit"}], %{system_prompt: "prepared"}}
    assert_receive {:executed, %{"value" => 1}}
  end

  test "preparation updates model limits and clears old provider state without resetting progress" do
    state =
      state(provider: {TestProvider, model: "old"}, model_metadata_overrides: %{"new" => 80_000})

    state = %{
      state
      | turn: 3,
        provider_state: %{response_id: "old"},
        provider_response_metadata: %{old: true},
        tool_calls: [%{id: "prior"}]
    }

    prepared =
      State.prepare(state,
        provider: {TestProvider, model: "new"},
        messages: [Message.user("new context")]
      )

    assert prepared.config.max_tokens == 80_000
    assert prepared.provider_state == %{}
    assert prepared.provider_response_metadata == %{}
    assert prepared.turn == 3
    assert prepared.started_at == state.started_at
    assert prepared.tool_calls == state.tool_calls
    assert prepared.messages == [Message.user("new context")]
  end

  test "preparation preserves state for unchanged providers and honors explicit new provider state" do
    state = %{
      state(provider: {TestProvider, model: "old"}, max_tokens: 1234)
      | provider_state: %{response_id: "existing"}
    }

    assert State.prepare(state, provider: {TestProvider, model: "old"}).provider_state ==
             state.provider_state

    prepared =
      State.prepare(state,
        provider: {TestProvider, model: "new", provider_state: %{response_id: "restored"}}
      )

    assert prepared.provider_state == %{response_id: "restored"}
    assert prepared.config.max_tokens == 1234
  end

  test "preparation accepts states initialized from a bare config" do
    state = State.init(%Config{provider: TestProvider, provider_config: %{}})
    prepared = State.prepare(state, provider: {TestProvider, model: "new"})
    assert prepared.config.provider_config.model == "new"
    assert is_binary(prepared.config.compaction.summary_prompt)
  end

  test "per-turn tools can change from research to submission" do
    owner = self()
    search = tool(name: "search")
    submit = tool()

    prepare = fn state ->
      State.prepare(state, tools: if(state.turn == 0, do: [search], else: [submit]))
    end

    {:ok, provider} =
      TestProvider.start_link([
        TestProvider.tool_use_response([%{call() | name: "search"}]),
        TestProvider.tool_use_response([call()])
      ])

    assert {:ok, %{turns: 2}} =
             Alloy.run("answer",
               provider: {RecordingProvider, owner: owner, agent_pid: provider},
               stop_after_tool: "submit",
               middleware: [Hooks],
               context: %{hooks: %{before_completion: prepare}}
             )

    assert_receive {:request, _, [%{name: "search"}], _}
    assert_receive {:request, _, [%{name: "submit"}], _}
  end

  test "preparation rejects unsupported inputs and duplicate tools" do
    for opts <- [[messages: ["raw"]], [system_prompt: 1], [unknown: true]] do
      assert_raise ArgumentError, fn -> State.prepare(state([]), opts) end
    end

    assert_raise ArgumentError, ~r/unique/, fn ->
      State.prepare(state([]), tools: [tool(), tool()])
    end
  end

  test "configuration rejects invalid new controls" do
    for opts <- [
          [tool_concurrency: 0],
          [tool_concurrency: -1],
          [tool_concurrency: 1.5],
          [tool_validation: :unknown],
          [stop_after_tool: ""],
          [stop_after_tool: :submit]
        ] do
      assert_raise ArgumentError, fn -> state(opts) end
    end
  end

  test "prepared context is budgeted before reaching the provider" do
    owner = self()

    prepare = fn state ->
      send(owner, :prepared)
      State.prepare(state, messages: [Message.user("short")])
    end

    {:ok, provider} = TestProvider.start_link([TestProvider.text_response("done")])

    assert {:ok, result} =
             Alloy.run("answer",
               provider: {RecordingProvider, owner: owner, agent_pid: provider},
               messages: [Message.user(String.duplicate("long ", 5_000))],
               max_tokens: 100,
               middleware: [Hooks],
               context: %{hooks: %{before_completion: prepare}}
             )

    assert result.text == "done"
    assert result.usage.input_tokens == 10
    assert_receive :prepared
    assert_receive {:request, [%Message{content: "short"}], [], _}
    refute_receive {:request, _, _, _}
  end

  test "explicit concurrency limit controls actual simultaneous execution" do
    owner = self()

    blocking =
      tool(
        execute: fn _, _ ->
          send(owner, {:started, self()})

          receive do
            :release -> {:ok, "done"}
          end
        end
      )

    state = state(tools: [blocking], tool_concurrency: 1)

    task =
      Task.async(fn ->
        Executor.execute_all([call(), call(%{"value" => 2}, "c2")], state.tool_fns, state, [])
      end)

    assert_receive {:started, first}
    refute_receive {:started, _}, 50
    send(first, :release)
    assert_receive {:started, second}
    send(second, :release)
    assert {:ok, _, _} = Task.await(task)
  end

  test "stop_after_tool still completes when after_tool_execution appends a user message" do
    append_note = fn state ->
      %{state | messages: state.messages ++ [Message.user("audit note")]}
    end

    {:ok, provider} =
      TestProvider.start_link([
        TestProvider.tool_use_response([call()]),
        TestProvider.text_response("unexpected second turn")
      ])

    assert {:ok, result} =
             Alloy.run("go",
               provider: {TestProvider, agent_pid: provider},
               tools: [tool()],
               stop_after_tool: "submit",
               middleware: [Hooks],
               context: %{hooks: %{after_tool_execution: append_note}}
             )

    assert result.turns == 1
    assert result.text == "answer"
    assert result.metadata.final_tool.name == "submit"
  end

  test "invalid middleware return values raise descriptive ArgumentError" do
    bad_after = fn _state -> {:halt, "stop"} end

    state =
      state(
        tools: [tool()],
        middleware: [Hooks],
        context: %{hooks: %{after_tool_call: bad_after}}
      )

    assert_raise ArgumentError, ~r/unsupported value.*:after_tool_call/, fn ->
      Executor.execute_all([call()], state.tool_fns, state, [])
    end

    bad_before = fn _state -> {:result, %{}} end

    state_before =
      state(
        tools: [tool()],
        middleware: [Hooks],
        context: %{hooks: %{before_tool_call: bad_before}}
      )

    assert_raise ArgumentError, ~r/unsupported value.*:before_tool_call/, fn ->
      Executor.execute_all([call()], state_before.tool_fns, state_before, [])
    end
  end
end
