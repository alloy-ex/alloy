defmodule Alloy.Memory.IntegrationTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Test.MemoryStore

  describe "Alloy.run/2 with :memory option" do
    test "raises when memory is configured with a non-Anthropic provider" do
      assert_raise ArgumentError, ~r/Anthropic-only/, fn ->
        Alloy.run("hi",
          provider: {Alloy.Provider.OpenAI, api_key: "sk-test", model: "gpt-5.4"},
          memory: {MemoryStore, self()}
        )
      end
    end

    test "raises on malformed :memory value" do
      assert_raise ArgumentError, ~r/must be a \{module, store_opts\} tuple/, fn ->
        Alloy.run("hi",
          provider: {Alloy.Provider.Anthropic, api_key: "sk-test", model: "claude-sonnet-4-6"},
          memory: :bogus
        )
      end
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

    test "injects the memory_20250818 tool and beta header when memory is set", %{plug: plug} do
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
      assert memory_tool["name"] == "memory"

      assert {"anthropic-beta", beta_values} =
               Enum.find(headers, fn {name, _} -> name == "anthropic-beta" end)

      assert String.contains?(beta_values, "context-management-2025-06-27")
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
    test "routes memory tool_use blocks through the router, not the executor" do
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
          memory: {MemoryStore, store_pid}
        )

      assert result.text == "noted"

      # By the time the second turn fires, the memory store should hold
      # the value the first turn wrote.
      assert_receive {:final_turn_store, store}
      assert store["/memories/note.md"] == "user prefers SI units"

      # The conversation should include a user/tool_result message with
      # the memory router's output — not a regular tool-call result.
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
      assert block.is_error == false
      assert block.content =~ "created"
    end
  end
end
