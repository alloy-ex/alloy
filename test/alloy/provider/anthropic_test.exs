defmodule Alloy.Provider.AnthropicTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.{Anthropic, Error}

  # We test by intercepting the HTTP call via a custom Req adapter
  # that returns canned responses.

  describe "complete/3 with text response" do
    test "returns normalized end_turn response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_01",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Hello!"}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
            })
        })

      messages = [Message.user("Hi")]

      assert {:ok, result} = Anthropic.complete(messages, [], config)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello!"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5
    end
  end

  describe "complete/3 with tool_use response" do
    test "returns normalized tool_use response with tool calls" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_02",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "text", "text" => "Let me read that file."},
                %{
                  "type" => "tool_use",
                  "id" => "toolu_01",
                  "name" => "read",
                  "input" => %{"file_path" => "mix.exs"}
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
            })
        })

      messages = [Message.user("Read mix.exs")]
      tool_defs = [%{name: "read", description: "Read a file", input_schema: %{}}]

      assert {:ok, result} = Anthropic.complete(messages, tool_defs, config)
      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages
      assert length(blocks) == 2

      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "toolu_01"
      assert tool_call.input == %{"file_path" => "mix.exs"}
    end
  end

  describe "stop reasons" do
    # https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons
    for {wire, expected} <- [
          {"end_turn", :end_turn},
          {"stop_sequence", :end_turn},
          {"tool_use", :tool_use},
          {"max_tokens", :max_tokens},
          {"model_context_window_exceeded", :max_tokens},
          {"pause_turn", :pause_turn},
          {"refusal", :refusal}
        ] do
      test "complete/3 maps #{wire} to #{inspect(expected)}" do
        config = config_with_response(%{status: 200, body: message_json(unquote(wire))})

        assert {:ok, %{stop_reason: unquote(expected)}} =
                 Anthropic.complete([Message.user("Hi")], [], config)
      end

      test "stream/4 maps #{wire} to #{inspect(expected)}" do
        config = config_with_sse_stream(text_stream("ok", %{"stop_reason" => unquote(wire)}))

        assert {:ok, %{stop_reason: unquote(expected)}} =
                 Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)
      end
    end

    test "complete/3 puts refusal stop_details in response_metadata" do
      details = %{"type" => "refusal", "category" => "cyber", "explanation" => "Declined."}

      config =
        config_with_response(%{
          status: 200,
          body: message_json("refusal", %{"content" => [], "stop_details" => details})
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :refusal
      assert result.response_metadata == %{stop_details: details}
    end

    test "stream/4 puts refusal stop_details from message_delta in response_metadata" do
      details = %{"type" => "refusal", "category" => nil, "explanation" => nil}

      config =
        config_with_sse_stream(
          text_stream("partial", %{"stop_reason" => "refusal", "stop_details" => details})
        )

      assert {:ok, result} =
               Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert result.stop_reason == :refusal
      assert result.response_metadata == %{stop_details: details}
    end

    test "omits response_metadata when stop_details is null" do
      config =
        config_with_response(%{
          status: 200,
          body: message_json("end_turn", %{"stop_details" => nil})
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Hi")], [], config)
      refute Map.has_key?(result, :response_metadata)
    end
  end

  describe "complete/3 message formatting" do
    test "formats user messages correctly" do
      config = config_that_captures_request()

      messages = [
        Message.user("Hello"),
        Message.assistant("Hi there"),
        Message.user("How are you?")
      ]

      # This will "fail" because our mock returns the request body, not a real response
      # But we can verify the request format
      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert length(decoded["messages"]) == 3
      assert hd(decoded["messages"])["role"] == "user"
      assert hd(decoded["messages"])["content"] == "Hello"
    end

    test "includes system prompt in request" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")

      Anthropic.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert decoded["system"] == "You are helpful."
    end

    test "includes tool definitions in request" do
      config = config_that_captures_request()

      tool_defs = [
        %{
          name: "read",
          description: "Read a file",
          input_schema: %{
            type: "object",
            properties: %{file_path: %{type: "string"}},
            required: ["file_path"]
          }
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [tool] = decoded["tools"]
      assert tool["name"] == "read"
      assert tool["description"] == "Read a file"
      assert tool["input_schema"]["type"] == "object"
    end

    test "includes allowed_callers in tool definition when present" do
      config = config_that_captures_request()

      tool_defs = [
        %{
          name: "list_agents",
          description: "List agents",
          input_schema: %{type: "object", properties: %{}},
          allowed_callers: [:human, :code_execution]
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [tool] = decoded["tools"]
      assert tool["name"] == "list_agents"
      assert tool["allowed_callers"] == ["direct", "code_execution_20260120"]
    end

    test "includes strict true on strict tools" do
      config = config_that_captures_request()

      tool_defs = [
        %{
          name: "search",
          description: "Search",
          strict: true,
          input_schema: %{
            type: "object",
            properties: %{query: %{type: "string"}},
            required: ["query"],
            additionalProperties: false
          }
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [tool] = decoded["tools"]
      assert tool["strict"] == true
    end

    test "omits allowed_callers from tool definition when not present" do
      config = config_that_captures_request()

      tool_defs = [
        %{
          name: "basic",
          description: "A basic tool",
          input_schema: %{type: "object", properties: %{}}
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert [tool] = decoded["tools"]
      assert tool["name"] == "basic"
      refute Map.has_key?(tool, "allowed_callers")
    end

    test "formats tool_result messages correctly" do
      config = config_that_captures_request()

      messages = [
        Message.user("Read mix.exs"),
        Message.assistant_blocks([
          %{type: "text", text: "Reading..."},
          %{type: "tool_use", id: "toolu_01", name: "read", input: %{"file_path" => "mix.exs"}}
        ]),
        Message.tool_results([
          Message.tool_result_block("toolu_01", "file contents here")
        ])
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      # tool_results become a user message with content blocks
      tool_result_msg = List.last(decoded["messages"])
      assert tool_result_msg["role"] == "user"
      assert is_list(tool_result_msg["content"])
      assert hd(tool_result_msg["content"])["type"] == "tool_result"
    end

    test "extra_body params merge into the request body" do
      config =
        config_that_captures_request()
        |> Map.put(:extra_body, %{
          mcp_servers: [%{type: "url", url: "https://mcp.example.test"}]
        })

      Anthropic.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert decoded["mcp_servers"] == [
               %{"type" => "url", "url" => "https://mcp.example.test"}
             ]
    end
  end

  describe "server_tools" do
    test "appends server tools after the generated tools" do
      config =
        config_that_captures_request()
        |> Map.put(:code_execution, true)
        |> Map.put(:server_tools, [
          %{"type" => "web_search_20260209", "name" => "web_search", "max_uses" => 3},
          %{type: "web_fetch_20260209", name: "web_fetch"}
        ])

      tool_defs = [%{name: "read", description: "Read", input_schema: %{}}]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}

      assert [
               %{"name" => "read"},
               %{"name" => "code_execution"},
               %{"type" => "web_search_20260209", "name" => "web_search", "max_uses" => 3},
               %{"type" => "web_fetch_20260209", "name" => "web_fetch"}
             ] = Jason.decode!(body)["tools"]
    end

    test "sends server tools when there are no local tools" do
      config =
        Map.put(config_that_captures_request(), :server_tools, [
          %{"type" => "web_search_20260209", "name" => "web_search"}
        ])

      Anthropic.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      assert [%{"name" => "web_search"}] = Jason.decode!(body)["tools"]
    end

    test "extra_body tools still replace every tool" do
      config =
        config_that_captures_request()
        |> Map.put(:server_tools, [%{"type" => "web_search_20260209", "name" => "web_search"}])
        |> Map.put(:extra_body, %{"tools" => [%{"type" => "bash_20250124", "name" => "bash"}]})

      tool_defs = [%{name: "read", description: "Read", input_schema: %{}}]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      assert [%{"name" => "bash"}] = Jason.decode!(body)["tools"]
    end
  end

  describe "code_execution support" do
    test "includes code_execution tool in request when code_execution is configured" do
      config =
        config_that_captures_request()
        |> Map.put(:code_execution, true)

      tool_defs = [
        %{
          name: "read",
          description: "Read a file",
          input_schema: %{type: "object", properties: %{}}
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      tools = decoded["tools"]
      assert length(tools) == 2

      code_exec_tool = Enum.find(tools, &(&1["type"] == "code_execution_20260521"))
      assert code_exec_tool != nil
      assert code_exec_tool["name"] == "code_execution"
    end

    test "adds anthropic-beta header for code_execution and merges extra beta headers" do
      config =
        config_that_captures_request()
        |> Map.put(:code_execution, true)
        |> Map.put(:extra_headers, [{"anthropic-beta", "context-1m-2025-08-07"}])

      Anthropic.complete([Message.user("Hi")], [], config)

      assert_received {:request_headers, headers}

      anthropic_beta_values =
        headers
        |> Enum.filter(fn {name, _value} -> String.downcase(name) == "anthropic-beta" end)
        |> Enum.map(fn {_name, value} -> value end)

      assert [merged_beta_header] = anthropic_beta_values

      merged_beta_values =
        merged_beta_header
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.sort()

      assert merged_beta_values == ["code-execution-2025-08-25", "context-1m-2025-08-07"]
    end

    test "emits advanced tool-use fields and beta header when used" do
      config = config_that_captures_request()

      tool_defs = [
        %{
          name: "search",
          description: "Search",
          input_schema: %{type: "object", properties: %{query: %{type: "string"}}},
          input_examples: [%{query: "release notes"}],
          defer_loading: true
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      assert_received {:request_headers, headers}

      decoded = Jason.decode!(body)
      assert [tool] = decoded["tools"]
      assert tool["input_examples"] == [%{"query" => "release notes"}]
      assert tool["defer_loading"] == true

      assert beta_values(headers) == ["advanced-tool-use-2025-11-20"]
    end

    test "advanced tool-use beta merges with memory beta" do
      config =
        config_that_captures_request()
        |> Map.put(:memory, {Alloy.Test.MemoryStore, %{}})

      tool_defs = [
        %{
          name: "search",
          description: "Search",
          input_schema: %{type: "object", properties: %{}},
          input_examples: [%{}]
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_headers, headers}

      assert beta_values(headers) == [
               "advanced-tool-use-2025-11-20",
               "context-management-2025-06-27"
             ]
    end

    test "does not add advanced tool-use beta when advanced fields are absent" do
      config = config_that_captures_request()

      tool_defs = [
        %{name: "read", description: "Read", input_schema: %{type: "object", properties: %{}}}
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_headers, headers}

      refute "advanced-tool-use-2025-11-20" in beta_values(headers)
    end

    test "does not include code_execution tool when code_execution is false" do
      config = config_that_captures_request()

      tool_defs = [
        %{
          name: "read",
          description: "Read a file",
          input_schema: %{type: "object", properties: %{}}
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      tools = decoded["tools"]
      assert length(tools) == 1
      refute Enum.any?(tools, &String.starts_with?(&1["type"] || "", "code_execution"))
    end

    test "parses server_tool_use response blocks" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_ce_01",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{
                  "type" => "server_tool_use",
                  "id" => "srvtoolu_01",
                  "name" => "read",
                  "input" => %{"file_path" => "mix.exs"}
                }
              ],
              "stop_reason" => "tool_use",
              "usage" => %{"input_tokens" => 20, "output_tokens" => 15}
            })
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Read mix.exs")], [], config)
      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      server_call = Enum.find(blocks, &(&1.type == "server_tool_use"))
      assert server_call != nil
      assert server_call.id == "srvtoolu_01"
      assert server_call.name == "read"
      assert server_call.input == %{"file_path" => "mix.exs"}
    end

    test "keeps server_tool_use in history and drops legacy server_tool_result blocks" do
      config = config_that_captures_request()

      # Shape written by Alloy <= 0.12.4, which answered server tools itself.
      messages = [
        Message.user("Run it"),
        Message.assistant_blocks([
          %{type: "server_tool_use", id: "srvtoolu_01", name: "code_execution", input: %{}},
          %{type: "tool_use", id: "toolu_01", name: "read", input: %{"file_path" => "a"}}
        ]),
        Message.tool_results([
          %{type: "server_tool_result", tool_use_id: "srvtoolu_01", content: "stale"},
          %{type: "tool_result", tool_use_id: "toolu_01", content: "file contents"}
        ])
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [_user, assistant, results] = decoded["messages"]
      assert Enum.map(assistant["content"], & &1["type"]) == ["server_tool_use", "tool_use"]
      assert [%{"type" => "tool_result", "tool_use_id" => "toolu_01"}] = results["content"]
    end
  end

  describe "programmatic tool calling" do
    # https://platform.claude.com/docs/en/agents-and-tools/tool-use/programmatic-tool-calling
    @caller %{"type" => "code_execution_20260120", "tool_id" => "srvtoolu_abc123"}

    test "translates allowed_callers to the API's caller names" do
      config = config_that_captures_request()

      tool_defs =
        for {name, callers} <- [
              {"legacy", [:human, :code_execution]},
              {"direct", [:direct]},
              {"raw", ["code_execution_20260521"]}
            ] do
          %{name: name, description: name, input_schema: %{}, allowed_callers: callers}
        end

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}

      assert Map.new(Jason.decode!(body)["tools"], &{&1["name"], &1["allowed_callers"]}) == %{
               "legacy" => ["direct", "code_execution_20260120"],
               "direct" => ["direct"],
               "raw" => ["code_execution_20260521"]
             }
    end

    test "complete/3 keeps the tool_use caller and stores the container in provider_state" do
      config =
        config_with_response(%{
          status: 200,
          body: Jason.encode!(programmatic_call_message())
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Top customers?")], [], config)
      assert result.stop_reason == :tool_use
      assert result.provider_state == %{container_id: "container_xyz789"}

      assert [%{type: "tool_use", id: "toolu_def456", caller: @caller}] =
               Message.tool_calls(hd(result.messages))
    end

    test "stream/4 keeps the tool_use caller and stores the container in provider_state" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 1, "output_tokens" => 1}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_def456",
              "name" => "query_database",
              "input" => %{},
              "caller" => @caller
            }
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"sql": "<sql>"})}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{
              "stop_reason" => "tool_use",
              "container" => %{"id" => "container_xyz789", "expires_at" => "2026-10-09T10:00:00Z"}
            },
            "usage" => %{"output_tokens" => 9}
          }),
          ant_event("message_stop", %{})
        ])

      assert {:ok, result} =
               Anthropic.stream([Message.user("Top customers?")], [], config, fn _ -> :ok end)

      assert result.provider_state == %{container_id: "container_xyz789"}

      assert [%{id: "toolu_def456", input: %{"sql" => "<sql>"}, caller: @caller}] =
               Message.tool_calls(hd(result.messages))
    end

    test "omits provider_state when the response has no container" do
      config = config_with_response(%{status: 200, body: message_json("end_turn")})

      assert {:ok, result} = Anthropic.complete([Message.user("Hi")], [], config)
      refute Map.has_key?(result, :provider_state)
    end

    test "sends the stored container and the tool_use caller on the next request" do
      config =
        config_that_captures_request()
        |> Map.put(:provider_state, %{container_id: "container_xyz789"})

      messages = [
        Message.user("Top customers?"),
        Message.assistant_blocks([
          %{type: "tool_use", id: "toolu_def456", name: "q", input: %{}, caller: @caller}
        ]),
        Message.tool_results([Message.tool_result_block("toolu_def456", "[]")])
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert decoded["container"] == "container_xyz789"
      assert [%{"caller" => @caller}] = Enum.at(decoded["messages"], 1)["content"]
    end

    test "sends no container before one exists" do
      config = config_that_captures_request()

      Anthropic.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      refute Map.has_key?(Jason.decode!(body), "container")
    end

    test "Alloy.run/2 continues a paused programmatic call in the same container" do
      test_pid = self()
      calls = :counters.new(1, [])

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(body)})
        :counters.add(calls, 1, 1)

        response =
          case :counters.get(calls, 1) do
            1 -> programmatic_call_message()
            _ -> Jason.decode!(message_json("end_turn"))
          end

        Req.Test.json(conn, response)
      end)

      query_database =
        Alloy.Tool.inline(
          name: "query_database",
          description: "Run SQL",
          input_schema: %{type: "object", properties: %{sql: %{type: "string"}}},
          allowed_callers: [:code_execution],
          execute: fn _input, _context -> {:ok, "[]"} end
        )

      assert {:ok, result} =
               Alloy.run("Top customers?",
                 provider:
                   {Anthropic,
                    api_key: "sk-ant-test-key",
                    model: "claude-sonnet-4-6",
                    code_execution: true,
                    req_options: [plug: {Req.Test, __MODULE__}]},
                 tools: [query_database]
               )

      assert result.status == :completed
      assert_received {:request_body, first}
      assert_received {:request_body, second}

      refute Map.has_key?(first, "container")
      assert second["container"] == "container_xyz789"

      [_user, assistant, results] = second["messages"]
      assert Enum.find(assistant["content"], &(&1["type"] == "tool_use"))["caller"] == @caller
      assert [%{"type" => "tool_result", "tool_use_id" => "toolu_def456"}] = results["content"]
    end
  end

  describe "complete/3 error handling" do
    test "returns error on HTTP failure" do
      config = config_with_response(%{status: 500, body: "Internal Server Error"})

      assert {:error, _reason} = Anthropic.complete([Message.user("Hi")], [], config)
    end

    test "returns error on API error response" do
      config =
        config_with_response(%{
          status: 400,
          body:
            Jason.encode!(%{
              "type" => "error",
              "error" => %{
                "type" => "invalid_request_error",
                "message" => "messages: at least one message is required"
              }
            })
        })

      assert {:error, %Error{kind: :invalid_request} = reason} =
               Anthropic.complete([Message.user("Hi")], [], config)

      assert Exception.message(reason) =~ "invalid_request_error"
    end

    test "returns error on overloaded response" do
      config =
        config_with_response(%{
          status: 529,
          body:
            Jason.encode!(%{
              "type" => "error",
              "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
            })
        })

      assert {:error, %Error{kind: :overloaded} = reason} =
               Anthropic.complete([Message.user("Hi")], [], config)

      assert Exception.message(reason) =~ "overloaded"
    end
  end

  describe "complete/3 with cache: true" do
    test "system prompt is sent as content block with cache_control when cache: true" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")
        |> Map.put(:cache, true)

      Anthropic.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      # System should be a list of content blocks, not a bare string
      assert is_list(decoded["system"])
      [system_block] = decoded["system"]
      assert system_block["type"] == "text"
      assert system_block["text"] == "You are helpful."
      assert system_block["cache_control"] == %{"type" => "ephemeral"}
    end

    test "system prompt is bare string when cache is not set" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")

      Anthropic.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      # Default: bare string, no cache_control
      assert decoded["system"] == "You are helpful."
    end

    test "last tool definition gets cache_control when cache: true" do
      config =
        config_that_captures_request()
        |> Map.put(:cache, true)

      tool_defs = [
        %{
          name: "read",
          description: "Read a file",
          input_schema: %{type: "object", properties: %{}}
        },
        %{
          name: "write",
          description: "Write a file",
          input_schema: %{type: "object", properties: %{}}
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      tools = decoded["tools"]
      assert length(tools) == 2

      # Only the LAST tool should have cache_control
      refute Map.has_key?(hd(tools), "cache_control")
      assert List.last(tools)["cache_control"] == %{"type" => "ephemeral"}
    end

    test "cache_control goes on the last tool that is not deferred" do
      # A deferred tool with cache_control is a 400:
      # https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool
      config = Map.put(config_that_captures_request(), :cache, true)

      tool_defs = [
        %{name: "read", description: "Read", input_schema: %{}},
        %{name: "write", description: "Write", input_schema: %{}},
        %{name: "search", description: "Search", input_schema: %{}, defer_loading: true}
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}

      assert Map.new(Jason.decode!(body)["tools"], &{&1["name"], &1["cache_control"]}) == %{
               "read" => nil,
               "write" => %{"type" => "ephemeral"},
               "search" => nil
             }
    end

    test "no tool gets cache_control when every tool is deferred" do
      config = Map.put(config_that_captures_request(), :cache, true)

      tool_defs = [
        %{name: "search", description: "Search", input_schema: %{}, defer_loading: true}
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      assert [tool] = Jason.decode!(body)["tools"]
      refute Map.has_key?(tool, "cache_control")
    end

    test "last message string content gets cache_control when cache: true" do
      config =
        config_that_captures_request()
        |> Map.put(:cache, true)

      Anthropic.complete([Message.user("Hi")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [message] = decoded["messages"]

      assert [%{"type" => "text", "text" => "Hi", "cache_control" => %{"type" => "ephemeral"}}] =
               message["content"]
    end

    test "last message block content gets cache_control on its last block" do
      config =
        config_that_captures_request()
        |> Map.put(:cache, true)

      messages = [
        %Message{
          role: :user,
          content: [
            %{type: "text", text: "First"},
            %{type: "text", text: "Second"}
          ]
        }
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [message] = decoded["messages"]
      [first, last] = message["content"]
      refute Map.has_key?(first, "cache_control")
      assert last["cache_control"] == %{"type" => "ephemeral"}
    end

    test "last message cache_control skips trailing thinking blocks" do
      config =
        config_that_captures_request()
        |> Map.put(:cache, true)

      messages = [
        %Message{
          role: :assistant,
          content: [
            %{type: "text", text: "Prefill"},
            %{type: "thinking", thinking: "Reasoning", signature: "sig_123"}
          ]
        }
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [message] = decoded["messages"]
      [text, thinking] = message["content"]

      assert text["cache_control"] == %{"type" => "ephemeral"}
      refute Map.has_key?(thinking, "cache_control")
    end

    test "last message cache_control is omitted when only thinking blocks qualify" do
      config =
        config_that_captures_request()
        |> Map.put(:cache, true)

      messages = [
        %Message{
          role: :assistant,
          content: [
            %{type: "thinking", thinking: "Reasoning", signature: "sig_123"},
            %{type: "redacted_thinking", data: "opaque"}
          ]
        }
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [message] = decoded["messages"]
      assert count_cache_controls(message) == 0
    end

    test "cache true keeps total cache_control breakpoints at three" do
      config =
        config_that_captures_request()
        |> Map.put(:system_prompt, "You are helpful.")
        |> Map.put(:cache, true)

      tool_defs = [
        %{name: "read", description: "Read", input_schema: %{type: "object", properties: %{}}}
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert count_cache_controls(decoded) <= 4
      assert count_cache_controls(decoded) == 3
    end

    test "tools have no cache_control when cache is not set" do
      config = config_that_captures_request()

      tool_defs = [
        %{
          name: "read",
          description: "Read a file",
          input_schema: %{type: "object", properties: %{}}
        }
      ]

      Anthropic.complete([Message.user("Hi")], tool_defs, config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      [tool] = decoded["tools"]
      refute Map.has_key?(tool, "cache_control")

      [message] = decoded["messages"]
      refute is_list(message["content"])
    end

    test "includes cache usage in response" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_03",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "Cached!"}],
              "stop_reason" => "end_turn",
              "usage" => %{
                "input_tokens" => 10,
                "output_tokens" => 5,
                "cache_creation_input_tokens" => 100,
                "cache_read_input_tokens" => 50
              }
            })
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Hi")], [], config)
      assert result.usage.cache_creation_input_tokens == 100
      assert result.usage.cache_read_input_tokens == 50
    end
  end

  describe "complete/3 multimodal formatting" do
    test "image block formats to Anthropic base64 source format" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [
            %{type: "text", text: "What is in this image?"},
            Message.image("image/jpeg", "base64data==")
          ]
        }
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      user_msg = hd(decoded["messages"])
      assert user_msg["role"] == "user"

      image_block = Enum.find(user_msg["content"], &(&1["type"] == "image"))
      assert image_block != nil
      assert image_block["source"]["type"] == "base64"
      assert image_block["source"]["media_type"] == "image/jpeg"
      assert image_block["source"]["data"] == "base64data=="
    end

    test "audio block formats gracefully (text fallback) since Anthropic does not support it" do
      config = config_that_captures_request()

      messages = [
        %Alloy.Message{
          role: :user,
          content: [Message.audio("audio/mp3", "audiodata")]
        }
      ]

      # Should not raise — graceful handling
      result = Anthropic.complete(messages, [], config)
      assert match?({:ok, _}, result)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      user_msg = hd(decoded["messages"])

      # The audio block should have been converted to some sendable form
      assert is_list(user_msg["content"])
      [block] = user_msg["content"]
      assert is_map(block)
    end
  end

  # ── stream/4 ──────────────────────────────────────────────────────────

  describe "stream/4" do
    test "emits text chunks and returns correct response" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 10, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hello"}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => " world"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 5}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} = Anthropic.stream([Message.user("Hi")], [], config, on_chunk)
      assert result.stop_reason == :end_turn
      assert [%Message{role: :assistant}] = result.messages
      assert Message.text(hd(result.messages)) == "Hello world"
      assert result.usage.input_tokens == 10
      assert result.usage.output_tokens == 5

      assert_received {:chunk, "Hello"}
      assert_received {:chunk, " world"}
      refute_received {:chunk, _}
    end

    test "takes cumulative message_delta usage instead of adding it to message_start" do
      # Numbers from the web search example in
      # https://platform.claude.com/docs/en/build-with-claude/streaming
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{
              "usage" => %{
                "input_tokens" => 2679,
                "cache_creation_input_tokens" => 0,
                "cache_read_input_tokens" => 0,
                "output_tokens" => 3
              }
            }
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Answer."}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn", "stop_sequence" => nil},
            "usage" => %{
              "input_tokens" => 10_682,
              "cache_creation_input_tokens" => 0,
              "cache_read_input_tokens" => nil,
              "output_tokens" => 510,
              "server_tool_use" => %{"web_search_requests" => 1}
            }
          }),
          ant_event("message_stop", %{})
        ])

      assert {:ok, result} = Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert result.usage == %{
               input_tokens: 10_682,
               output_tokens: 510,
               cache_creation_input_tokens: 0,
               cache_read_input_tokens: 0
             }
    end

    test "accumulates tool call input_json_delta without emitting chunks" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 20, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_01",
              "name" => "read",
              "input" => %{}
            }
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"file_path\""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ": \"mix.exs\"}"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 15}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} =
               Anthropic.stream([Message.user("Read mix.exs")], [], config, on_chunk)

      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      tool_call = Enum.find(blocks, &(&1.type == "tool_use"))
      assert tool_call.name == "read"
      assert tool_call.id == "toolu_01"
      assert tool_call.input == %{"file_path" => "mix.exs"}

      # No text chunks emitted for tool calls
      refute_received {:chunk, _}
    end

    test "request body includes stream: true" do
      config =
        config_with_sse_stream_capturing_request([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 1, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "ok"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 1}
          }),
          ant_event("message_stop", %{})
        ])

      Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)
      assert decoded["stream"] == true
    end

    test "handles mixed text and tool use in same stream" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 15, "output_tokens" => 0}}
          }),
          # Text block at index 0
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Let me read that."}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          # Tool use block at index 1
          ant_event("content_block_start", %{
            "index" => 1,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_02",
              "name" => "read",
              "input" => %{}
            }
          }),
          ant_event("content_block_delta", %{
            "index" => 1,
            "delta" => %{
              "type" => "input_json_delta",
              "partial_json" => "{\"file_path\": \"mix.exs\"}"
            }
          }),
          ant_event("content_block_stop", %{"index" => 1}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 20}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      assert {:ok, result} =
               Anthropic.stream([Message.user("Read mix.exs")], [], config, on_chunk)

      assert result.stop_reason == :tool_use
      assert [%Message{role: :assistant, content: blocks}] = result.messages

      assert Enum.find(blocks, &(&1.type == "text"))
      assert Enum.find(blocks, &(&1.type == "tool_use"))

      assert_received {:chunk, "Let me read that."}
    end

    test "returns parsed error when stream response is non-200" do
      error_body =
        Jason.encode!(%{
          "type" => "error",
          "error" => %{
            "type" => "invalid_request_error",
            "message" => "max_tokens: must be less than 8192"
          }
        })

      config = config_with_sse_error_stream(400, error_body)

      assert {:error, reason} =
               Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert Exception.message(reason) =~ "invalid_request_error"
      assert Exception.message(reason) =~ "max_tokens"
    end

    test "returns a classified error for an in-band error event" do
      # https://platform.claude.com/docs/en/build-with-claude/streaming#error-events
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 1, "output_tokens" => 1}}
          }),
          ant_event("error", %{
            "type" => "error",
            "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
          })
        ])

      assert {:error, %Error{kind: :overloaded, type: "overloaded_error"} = error} =
               Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert Error.retryable?(error)
      assert Exception.message(error) == "overloaded_error: Overloaded"
    end

    test "an error event after partial output still fails the stream" do
      chunks =
        "partial"
        |> text_stream(%{"stop_reason" => "end_turn"})
        |> Enum.take(4)
        |> Kernel.++([
          ant_event("error", %{
            "type" => "error",
            "error" => %{"type" => "api_error", "message" => "Internal server error"}
          })
        ])

      assert {:error, %Error{kind: :server_error}} =
               Anthropic.stream([Message.user("Hi")], [], config_with_sse_stream(chunks), fn _ ->
                 :ok
               end)
    end

    test "returns an error when the stream ends without a stop_reason" do
      truncated = "cut off" |> text_stream(%{"stop_reason" => "end_turn"}) |> Enum.take(3)

      assert {:error, %Error{kind: :network} = error} =
               Anthropic.stream(
                 [Message.user("Hi")],
                 [],
                 config_with_sse_stream(truncated),
                 fn _ -> :ok end
               )

      assert Error.retryable?(error)
      assert Exception.message(error) =~ "stop_reason"
    end

    test "Alloy.stream/3 retries an in-band overloaded error that arrived before any output" do
      attempts = :counters.new(1, [])

      overloaded =
        ant_event("error", %{
          "type" => "error",
          "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
        })

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(attempts, 1, 1)

        chunks =
          case :counters.get(attempts, 1) do
            1 -> [overloaded]
            _ -> text_stream("Recovered", %{"stop_reason" => "end_turn"})
          end

        Enum.reduce(chunks, Plug.Conn.send_chunked(conn, 200), fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)

      provider_config = [
        api_key: "sk-ant-test-key",
        model: "claude-sonnet-4-6",
        req_options: [plug: {Req.Test, __MODULE__}]
      ]

      assert {:ok, result} =
               Alloy.stream("Hi", fn _ -> :ok end,
                 provider: {Anthropic, provider_config},
                 max_retries: 1,
                 retry_backoff_ms: 1
               )

      assert result.text == "Recovered"
      assert :counters.get(attempts, 1) == 2
    end

    test "returns raw body when stream error is not JSON" do
      config = config_with_sse_error_stream(502, "Bad Gateway")

      assert {:error, reason} =
               Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      assert %Error{kind: :server_error} = reason
      assert Exception.message(reason) == "HTTP 502: Bad Gateway"
    end
  end

  # ── Extended Thinking ────────────────────────────────────────────────

  describe "complete/3 with thinking blocks" do
    test "returns thinking block in message content for round-trip" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_think_01",
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{
                  "type" => "thinking",
                  "thinking" => "Let me reason through this...",
                  "signature" => "sig_abc123"
                },
                %{"type" => "text", "text" => "The answer is 42."}
              ],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 30}
            })
        })

      assert {:ok, result} = Anthropic.complete([Message.user("Hard question")], [], config)

      # text/1 returns only the text content
      assert Message.text(hd(result.messages)) == "The answer is 42."

      # thinking block is preserved in content for round-trip
      [thinking_block, _text_block] = hd(result.messages).content
      assert thinking_block.type == "thinking"
      assert thinking_block.thinking == "Let me reason through this..."
      assert thinking_block.signature == "sig_abc123"
    end

    test "includes thinking in request body when extended_thinking opt set" do
      config =
        config_that_captures_request()
        |> Map.put(:extended_thinking, budget_tokens: 5_000)

      Anthropic.complete([Message.user("Think hard")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assert %{"type" => "enabled", "budget_tokens" => 5_000} = decoded["thinking"]
    end

    test "raises ArgumentError when extended_thinking is set without budget_tokens" do
      config =
        config_that_captures_request()
        |> Map.put(:extended_thinking, [])

      assert_raise ArgumentError, ~r/budget_tokens/, fn ->
        Anthropic.complete([Message.user("Think hard")], [], config)
      end
    end

    test "no thinking key in request body when extended_thinking not set" do
      config = config_that_captures_request()

      Anthropic.complete([Message.user("Simple question")], [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      refute Map.has_key?(decoded, "thinking")
    end

    test "ignores extended_thinking when value is not a keyword list" do
      config =
        config_with_response(%{
          status: 200,
          body:
            Jason.encode!(%{
              "id" => "msg_ignore_thinking",
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "ok"}],
              "stop_reason" => "end_turn",
              "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
            })
        })
        |> Map.put(:extended_thinking, true)

      assert {:ok, _result} = Anthropic.complete([Message.user("Think hard")], [], config)
    end

    test "thinking block round-trips correctly through format_content_block" do
      # A message with a thinking block should be serialisable back to Anthropic's
      # wire format so subsequent turns include the thinking block verbatim.
      config = config_that_captures_request()

      thinking_block = %{type: "thinking", thinking: "My reasoning...", signature: "sig_xyz"}
      text_block = %{type: "text", text: "My answer."}

      messages = [
        Message.user("Question"),
        %Message{role: :assistant, content: [thinking_block, text_block]}
      ]

      Anthropic.complete(messages, [], config)

      assert_received {:request_body, body}
      decoded = Jason.decode!(body)

      assistant_msg = Enum.find(decoded["messages"], &(&1["role"] == "assistant"))
      thinking_wire = Enum.find(assistant_msg["content"], &(&1["type"] == "thinking"))

      assert thinking_wire["thinking"] == "My reasoning..."
      assert thinking_wire["signature"] == "sig_xyz"
    end
  end

  describe "stream/4 with thinking blocks" do
    test "emits thinking deltas via on_event, not on_chunk" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 10, "output_tokens" => 0}}
          }),
          # Thinking block at index 0
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "thinking", "thinking" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "Let me think..."}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => " Step 2."}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          # Text block at index 1
          ant_event("content_block_start", %{
            "index" => 1,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 1,
            "delta" => %{"type" => "text_delta", "text" => "Answer."}
          }),
          ant_event("content_block_stop", %{"index" => 1}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 20}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      on_event = fn event -> send(test_pid, {:event, event}) end
      config = Map.put(config, :on_event, on_event)

      assert {:ok, result} = Anthropic.stream([Message.user("Think")], [], config, on_chunk)

      # on_chunk receives only text deltas
      assert_received {:chunk, "Answer."}
      refute_received {:chunk, _}

      # on_event receives thinking deltas from the provider.
      # :text_delta is emitted by Turn.wrapped_chunk, not by the provider directly.
      assert_received {:event, {:thinking_delta, "Let me think..."}}
      assert_received {:event, {:thinking_delta, " Step 2."}}
      refute_received {:event, {:text_delta, _}}

      # Result text is text-only
      assert Message.text(hd(result.messages)) == "Answer."

      # Thinking block is in content for round-trip
      [thinking_block | _] = hd(result.messages).content
      assert thinking_block.type == "thinking"
      assert thinking_block.thinking == "Let me think... Step 2."
    end

    test "provider does not emit :text_delta directly (Turn.wrapped_chunk handles it)" do
      # :text_delta is emitted by Turn.wrapped_chunk for all providers universally.
      # The Anthropic provider itself only emits :thinking_delta via on_event.
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 5, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hello"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 3}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_event = fn event -> send(test_pid, {:event, event}) end
      config = Map.put(config, :on_event, on_event)

      Anthropic.stream([Message.user("Hi")], [], config, fn _ -> :ok end)

      # Provider does NOT emit :text_delta — Turn.wrapped_chunk does
      refute_received {:event, {:text_delta, _}}
    end

    test "signature_delta is captured in streamed thinking block" do
      # Anthropic streams thinking in three delta phases:
      # thinking_delta (text), signature_delta (signature), then content_block_stop.
      # The signature must survive into the parsed thinking block for round-trip.
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 10, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "thinking", "thinking" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "My reasoning."}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "sig_streamed123"}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("content_block_start", %{
            "index" => 1,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 1,
            "delta" => %{"type" => "text_delta", "text" => "Done."}
          }),
          ant_event("content_block_stop", %{"index" => 1}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 5}
          }),
          ant_event("message_stop", %{})
        ])

      assert {:ok, result} =
               Anthropic.stream([Message.user("Think")], [], config, fn _ -> :ok end)

      [thinking_block | _] = hd(result.messages).content
      assert thinking_block.type == "thinking"
      assert thinking_block.thinking == "My reasoning."
      assert thinking_block.signature == "sig_streamed123"
    end

    test "works normally when on_event is not set" do
      config =
        config_with_sse_stream([
          ant_event("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 5, "output_tokens" => 0}}
          }),
          ant_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "thinking", "thinking" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "thinking..."}
          }),
          ant_event("content_block_stop", %{"index" => 0}),
          ant_event("content_block_start", %{
            "index" => 1,
            "content_block" => %{"type" => "text", "text" => ""}
          }),
          ant_event("content_block_delta", %{
            "index" => 1,
            "delta" => %{"type" => "text_delta", "text" => "Done."}
          }),
          ant_event("content_block_stop", %{"index" => 1}),
          ant_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 10}
          }),
          ant_event("message_stop", %{})
        ])

      test_pid = self()
      on_chunk = fn chunk -> send(test_pid, {:chunk, chunk}) end

      # No on_event in config — should work fine, no crash
      assert {:ok, result} = Anthropic.stream([Message.user("Hi")], [], config, on_chunk)
      assert Message.text(hd(result.messages)) == "Done."
      assert_received {:chunk, "Done."}
    end
  end

  describe "complete/3 retry behavior" do
    test "returns error on 429 (retry is handled by Turn, not the provider)" do
      # Req retry is disabled — providers return errors immediately for Turn to retry.
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 429, "Too Many Requests")
      end)

      config = %{
        api_key: "sk-ant-test-key",
        model: "claude-sonnet-4-6",
        max_tokens: 4096,
        req_options: [plug: {Req.Test, __MODULE__}]
      }

      assert {:error, %Error{kind: :rate_limited} = error} =
               Anthropic.complete([Message.user("Hi")], [], config)

      assert Exception.message(error) == "HTTP 429: Too Many Requests"
    end

    test "req_options cannot re-enable Req retry (retry: false is enforced)" do
      # A caller might pass retry: :transient in req_options. This must NOT
      # re-enable Req's built-in retry, because Turn handles all retry logic.
      calls = :counters.new(1, [:atomics])

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(calls, 1, 1)
        Plug.Conn.send_resp(conn, 429, "Too Many Requests")
      end)

      config = %{
        api_key: "sk-ant-test-key",
        model: "claude-sonnet-4-6",
        max_tokens: 4096,
        req_options: [
          plug: {Req.Test, __MODULE__},
          retry: :transient,
          retry_delay: 1
        ]
      }

      assert {:error, %Error{kind: :rate_limited} = error} =
               Anthropic.complete([Message.user("Hi")], [], config)

      assert Exception.message(error) == "HTTP 429: Too Many Requests"

      # Must have been called exactly once — no Req retry
      assert :counters.get(calls, 1) == 1,
             "Expected 1 call but got #{:counters.get(calls, 1)} — Req retry was not disabled"
    end
  end

  # --- Test Helpers ---

  defp config_with_response(response) do
    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      req_options: [
        plug: {Req.Test, __MODULE__},
        retry: false
      ]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, response.status, response.body)
      end)
    end)
  end

  # Step 2 of the programmatic tool calling workflow in
  # https://platform.claude.com/docs/en/agents-and-tools/tool-use/programmatic-tool-calling
  defp programmatic_call_message do
    %{
      "id" => "msg_ptc",
      "type" => "message",
      "role" => "assistant",
      "content" => [
        %{
          "type" => "server_tool_use",
          "id" => "srvtoolu_abc123",
          "name" => "code_execution",
          "input" => %{"code" => "rows = await query_database({'sql': '<sql>'})"}
        },
        %{
          "type" => "tool_use",
          "id" => "toolu_def456",
          "name" => "query_database",
          "input" => %{"sql" => "<sql>"},
          "caller" => %{"type" => "code_execution_20260120", "tool_id" => "srvtoolu_abc123"}
        }
      ],
      "container" => %{"id" => "container_xyz789", "expires_at" => "2026-10-09T10:00:00Z"},
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 20}
    }
  end

  defp message_json(stop_reason, overrides \\ %{}) do
    %{
      "id" => "msg_stop",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => "ok"}],
      "stop_reason" => stop_reason,
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  # --- SSE Streaming Helpers ---

  # Build an Anthropic-format SSE event string: "event: <type>\ndata: <json>\n\n"
  defp ant_event(type, data) do
    "event: #{type}\ndata: #{Jason.encode!(data)}\n\n"
  end

  # A complete one-text-block stream whose message_delta carries `delta`.
  defp text_stream(text, delta) do
    [
      ant_event("message_start", %{
        "message" => %{"usage" => %{"input_tokens" => 1, "output_tokens" => 1}}
      }),
      ant_event("content_block_start", %{
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }),
      ant_event("content_block_delta", %{
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      }),
      ant_event("content_block_stop", %{"index" => 0}),
      ant_event("message_delta", %{"delta" => delta, "usage" => %{"output_tokens" => 2}}),
      ant_event("message_stop", %{})
    ]
  end

  defp config_with_sse_stream(chunks) do
    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(chunks, conn, fn chunk, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, chunk)
          conn
        end)
      end)
    end)
  end

  defp config_with_sse_stream_capturing_request(chunks) do
    test_pid = self()

    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(
        __MODULE__,
        Alloy.StreamTestHelpers.sse_chunks_capturing_plug(test_pid, chunks)
      )
    end)
  end

  defp config_with_sse_error_stream(status, body) do
    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, status)
        {:ok, conn} = Plug.Conn.chunk(conn, body)
        conn
      end)
    end)
  end

  defp config_that_captures_request do
    test_pid = self()

    %{
      api_key: "sk-ant-test-key",
      model: "claude-sonnet-4-6",
      max_tokens: 4096,
      req_options: [
        plug: {Req.Test, __MODULE__},
        retry: false
      ]
    }
    |> tap(fn _ ->
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, body})
        send(test_pid, {:request_headers, conn.req_headers})

        Plug.Conn.send_resp(
          conn,
          200,
          Jason.encode!(%{
            "id" => "msg_capture",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "ok"}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
          })
        )
      end)
    end)
  end

  defp count_cache_controls(value) when is_map(value) do
    own = if Map.has_key?(value, "cache_control"), do: 1, else: 0

    own +
      (value
       |> Map.values()
       |> Enum.map(&count_cache_controls/1)
       |> Enum.sum())
  end

  defp count_cache_controls(value) when is_list(value) do
    value
    |> Enum.map(&count_cache_controls/1)
    |> Enum.sum()
  end

  defp count_cache_controls(_value), do: 0

  defp beta_values(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> String.downcase(name) == "anthropic-beta" end)
    |> Enum.flat_map(fn {_name, value} -> String.split(value, ",", trim: true) end)
    |> Enum.map(&String.trim/1)
    |> Enum.sort()
  end
end
