defmodule Alloy.Memory.IntegrationTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.Test, as: TestProvider
  alias Alloy.Test.{EchoTool, MemoryStore}

  describe "Alloy.run/2 with :memory option" do
    test "raises on a malformed :memory value" do
      assert_raise ArgumentError, ~r/expects a \{module, store\} tuple/, fn ->
        Alloy.run("hi",
          provider: {Alloy.Provider.Anthropic, api_key: "sk-test", model: "claude-sonnet-5-5"},
          memory: :bogus
        )
      end
    end

    test "raises when a configured tool is also named memory" do
      other_memory =
        Alloy.Tool.inline(
          name: "memory",
          description: "The app's own memory tool",
          input_schema: %{type: "object"},
          execute: fn _input, _context -> {:ok, "ok"} end
        )

      assert_raise ArgumentError, ~r/tool names must be unique.*"memory"/, fn ->
        Alloy.run("hi",
          provider: {TestProvider, []},
          memory: {MemoryStore, self()},
          tools: [other_memory]
        )
      end
    end

    test "other providers get the memory tool as a function with a JSON schema" do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:captured, Jason.decode!(body)})

        response = %{
          "id" => "resp_1",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "ok"}]
            }
          ],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      {:ok, store_pid} = MemoryStore.start_link()

      {:ok, _result} =
        Alloy.run("hello",
          provider:
            {Alloy.Provider.OpenAI,
             api_key: "sk-test", model: "gpt-6-sol", req_options: [plug: plug]},
          memory: {MemoryStore, store_pid}
        )

      assert_receive {:captured, body}
      assert [tool] = body["tools"]
      assert %{"type" => "function", "name" => "memory", "parameters" => parameters} = tool
      assert parameters["required"] == ["command"]
      assert "str_replace" in parameters["properties"]["command"]["enum"]
    end
  end

  describe "Anthropic provider request body" do
    # Drive the Anthropic provider via its req_options hook so we can
    # capture the outgoing request body and headers without a real HTTP
    # call. Req's :plug option routes the request to a Plug function.
    setup do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:captured, conn.req_headers, Jason.decode!(body)})

        response = %{
          "type" => "message",
          "role" => "assistant",
          "stop_reason" => "end_turn",
          "content" => [%{"type" => "text", "text" => "ok"}],
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      {:ok, plug: plug}
    end

    test "sends the memory tool as the memory_20250818 type without a beta header", %{
      plug: plug
    } do
      {:ok, store_pid} = MemoryStore.start_link()

      {:ok, _result} =
        Alloy.run("hello",
          provider:
            {Alloy.Provider.Anthropic,
             api_key: "sk-test", model: "claude-sonnet-4-6", req_options: [plug: plug]},
          memory: {MemoryStore, store_pid}
        )

      assert_receive {:captured, headers, body}

      assert [memory_tool] = Enum.filter(body["tools"] || [], &(&1["type"] == "memory_20250818"))

      assert Map.delete(memory_tool, "cache_control") == %{
               "type" => "memory_20250818",
               "name" => "memory"
             }

      # The memory tool is GA (no beta header) since February 17, 2026.
      refute List.keymember?(headers, "anthropic-beta", 0)
    end

    test "omits the memory tool and beta header when memory is absent", %{plug: plug} do
      {:ok, _result} =
        Alloy.run("hello",
          provider:
            {Alloy.Provider.Anthropic,
             api_key: "sk-test", model: "claude-sonnet-4-6", req_options: [plug: plug]}
        )

      assert_receive {:captured, headers, body}

      refute Enum.any?(body["tools"] || [], &(&1["type"] == "memory_20250818"))

      beta = Enum.find(headers, fn {name, _} -> name == "anthropic-beta" end)

      case beta do
        nil -> :ok
        {_, value} -> refute String.contains?(value, "context-management-2025-06-27")
      end
    end
  end

  describe "Turn loop with memory tool call" do
    # Simulate a two-turn flow: turn 1 Claude calls `memory.create`;
    # turn 2 Claude returns end_turn text. The provider plug serves
    # both responses in order.
    test "runs memory calls through the executor like any other tool" do
      {:ok, store_pid} = MemoryStore.start_link()

      state = :counters.new(1, [])
      parent = self()

      plug = fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)
        turn = :counters.add(state, 1, 1) |> then(fn _ -> :counters.get(state, 1) end)

        response =
          case turn do
            1 ->
              %{
                "type" => "message",
                "role" => "assistant",
                "stop_reason" => "tool_use",
                "content" => [
                  %{
                    "type" => "tool_use",
                    "id" => "toolu_mem1",
                    "name" => "memory",
                    "input" => %{
                      "command" => "create",
                      "path" => "/memories/note.md",
                      "file_text" => "user prefers SI units"
                    }
                  }
                ],
                "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
              }

            _ ->
              send(parent, {:final_turn_store, MemoryStore.contents(store_pid)})

              %{
                "type" => "message",
                "role" => "assistant",
                "stop_reason" => "end_turn",
                "content" => [%{"type" => "text", "text" => "noted"}],
                "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
              }
          end

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(response))
      end

      {:ok, result} =
        Alloy.run("remember my preferences",
          provider:
            {Alloy.Provider.Anthropic,
             api_key: "sk-test", model: "claude-sonnet-4-6", req_options: [plug: plug]},
          memory: {MemoryStore, store_pid},
          middleware: [Alloy.Test.ReportToolCalls],
          context: %{report_to: parent},
          on_event: &send(parent, {:event, &1.event})
        )

      assert result.text == "noted"

      # Middleware and tool events see memory calls; they used to bypass both.
      assert_received {:before_tool_call, "memory"}
      assert_received {:event, :tool_start}
      assert_received {:event, :tool_end}
      assert [%{name: "memory", error: nil}] = result.tool_calls

      # By the time the second turn fires, the memory store should hold
      # the value the first turn wrote.
      assert_receive {:final_turn_store, store}
      assert store["/memories/note.md"] == "user prefers SI units"

      # The conversation should include a user/tool_result message with
      # the store's output.
      tool_result_msg =
        Enum.find(result.messages, fn
          %Message{role: :user, content: blocks} when is_list(blocks) ->
            Enum.any?(blocks, &(is_map(&1) and &1[:type] == "tool_result"))

          _ ->
            false
        end)

      assert tool_result_msg
      [block] = tool_result_msg.content
      assert block.tool_use_id == "toolu_mem1"
      refute block[:is_error]
      assert block.content =~ "created"
    end
  end

  describe "memory calls through the executor" do
    test "calls in one response run in the order the model made them, alongside other tools" do
      {:ok, store_pid} = MemoryStore.start_link()
      memory = fn id, input -> %{id: id, name: "memory", input: input} end

      {:ok, provider} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            memory.("m1", %{
              "command" => "create",
              "path" => "/memories/prefs.md",
              "file_text" => "units: imperial"
            }),
            %{id: "e1", name: "echo", input: %{"text" => "hi"}},
            memory.("m2", %{
              "command" => "str_replace",
              "path" => "/memories/prefs.md",
              "old_str" => "imperial",
              "new_str" => "SI"
            })
          ]),
          TestProvider.text_response("Saved")
        ])

      {:ok, result} =
        Alloy.run("remember SI units",
          provider: {TestProvider, agent_pid: provider},
          tools: [EchoTool],
          memory: {MemoryStore, store_pid}
        )

      assert MemoryStore.contents(store_pid) == %{"/memories/prefs.md" => "units: SI"}
      assert Enum.map(result.tool_calls, & &1.id) == ["m1", "e1", "m2"]
      assert Enum.all?(result.tool_calls, &is_nil(&1.error))
    end
  end
end
