defmodule Alloy.ReasoningAndEventsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Alloy.Agent.{Config, State}
  alias Alloy.Context.Compactor
  alias Alloy.Message
  alias Alloy.Provider
  alias Alloy.Provider.{Anthropic, Codex, Error, Gemini, OpenAI, OpenAICompat, XAI}
  alias Alloy.Provider.Test, as: TestProvider
  alias Alloy.Tool.Core.Bash
  alias Alloy.Tool.Inline
  alias Alloy.Usage

  defmodule UpdateReasoningMiddleware do
    @behaviour Alloy.Middleware

    @impl true
    def call(:before_completion, %{turn: 0} = state) do
      State.prepare(state, reasoning: :low)
    end

    def call(_hook, state), do: state
  end

  defmodule HaltTurn2Middleware do
    @behaviour Alloy.Middleware

    @impl true
    def call(:before_completion, %{turn: 1}), do: {:halt, "stop before turn 2"}
    def call(_hook, state), do: state
  end

  defmodule CaptureReasoningProvider do
    @behaviour Alloy.Provider

    @impl true
    def complete(_messages, _tools, config) do
      send(config.test_pid, {:captured_reasoning, config.label, Map.get(config, :reasoning)})

      if Map.get(config, :fail?, false) do
        {:error, %Error{kind: :auth, message: "primary failed"}}
      else
        {:ok,
         %{
           stop_reason: :end_turn,
           messages: [Message.assistant("ok")],
           usage: %{input_tokens: 1, output_tokens: 1}
         }}
      end
    end
  end

  describe "Provider.normalize_reasoning/1, Config, and State.prepare/2" do
    test "normalizes valid reasoning atoms and maps and rejects invalid shapes" do
      assert {:ok, nil} = Provider.normalize_reasoning(nil)

      for effort <- [:off, :low, :medium, :high, :xhigh] do
        assert {:ok, %{effort: ^effort, display: nil}} = Provider.normalize_reasoning(effort)
      end

      assert {:ok, %{effort: :high, display: :summarized}} =
               Provider.normalize_reasoning(%{effort: :high, display: :summarized})

      assert {:ok, %{effort: :medium, display: :omitted}} =
               Provider.normalize_reasoning(%{effort: :medium, display: :omitted})

      # :off ignores/clears display hint
      assert {:ok, %{effort: :off, display: nil}} =
               Provider.normalize_reasoning(%{effort: :off, display: :summarized})

      for bad <- [
            :max,
            "high",
            %{},
            %{effort: :invalid},
            %{effort: :high, display: :raw},
            %{effort: :high, extra: true}
          ] do
        assert {:error, %Error{kind: :invalid_request}} = Provider.normalize_reasoning(bad)
        assert_raise ArgumentError, fn -> Provider.normalize_reasoning!(bad) end
      end
    end

    test "Config validates top-level, primary, and fallback :reasoning and State.prepare/2 updates it" do
      cfg =
        Config.from_opts(
          provider: {TestProvider, reasoning: :high},
          reasoning: :medium,
          fallback_providers: [{TestProvider, reasoning: :low}]
        )

      assert cfg.reasoning == %{effort: :medium, display: nil}
      assert cfg.provider_config.reasoning == %{effort: :high, display: nil}

      assert [{TestProvider, %{reasoning: %{effort: :low, display: nil}}}] =
               cfg.fallback_providers

      assert_raise ArgumentError, ~r/Invalid :reasoning/, fn ->
        Config.from_opts(provider: TestProvider, reasoning: :turbo)
      end

      assert_raise ArgumentError, ~r/Invalid :reasoning/, fn ->
        Config.from_opts(
          provider: TestProvider,
          fallback_providers: [{TestProvider, reasoning: :turbo}]
        )
      end

      state = State.init(cfg, [Message.user("hi")])
      updated = State.prepare(state, reasoning: %{effort: :xhigh, display: :summarized})
      assert updated.config.reasoning == %{effort: :xhigh, display: :summarized}
      # Previous provider-level :reasoning was cleared so the prepared value takes effect.
      refute Map.has_key?(updated.config.provider_config, :reasoning)
    end

    test "forwards top-level :reasoning to fallbacks while allowing fallback overrides and middleware updates" do
      parent = self()

      assert {:ok, %{text: "ok"}} =
               Alloy.run("Hi",
                 provider:
                   {CaptureReasoningProvider, test_pid: parent, label: :primary, fail?: true},
                 reasoning: :high,
                 fallback_providers: [
                   {CaptureReasoningProvider, test_pid: parent, label: :fb_inherit, fail?: true},
                   {CaptureReasoningProvider,
                    test_pid: parent, label: :fb_override, reasoning: :off}
                 ],
                 max_retries: 0
               )

      assert_received {:captured_reasoning, :primary, %{effort: :high, display: nil}}
      assert_received {:captured_reasoning, :fb_inherit, %{effort: :high, display: nil}}
      assert_received {:captured_reasoning, :fb_override, %{effort: :off, display: nil}}

      # Middleware State.prepare(reasoning: :low) overrides initial provider-level :reasoning.
      assert {:ok, %{text: "ok"}} =
               Alloy.run("Hi",
                 provider:
                   {CaptureReasoningProvider, test_pid: parent, label: :mw, reasoning: :xhigh},
                 middleware: [UpdateReasoningMiddleware],
                 max_retries: 0
               )

      assert_received {:captured_reasoning, :mw, %{effort: :low, display: nil}}
    end
  end

  describe "portable :reasoning across all 6 providers" do
    test "Anthropic translates effort/display, coexists with :output_schema, omits on :off, and respects extra_body" do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:ant_body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "id" => "msg_1",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => ~s({"ok":true})}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 5}
          })
        )
      end

      base = %{api_key: "sk-ant", model: "claude-sonnet-5-5", req_options: [plug: plug]}

      schema =
        Alloy.OutputSchema.normalize!(%{type: "object", properties: %{ok: %{type: "boolean"}}})

      # :xhigh + :summarized + :output_schema coexist cleanly
      assert {:ok, _} =
               Anthropic.complete(
                 [Message.user("hi")],
                 [],
                 Map.merge(base, %{
                   reasoning: %{effort: :xhigh, display: :summarized},
                   output_schema: schema
                 })
               )

      assert_received {:ant_body, body1}
      assert body1["thinking"] == %{"type" => "adaptive", "display" => "summarized"}
      assert body1["output_config"]["effort"] == "max"
      assert body1["output_config"]["format"]["type"] == "json_schema"

      # :off omits thinking and output_config.effort
      assert {:ok, _} =
               Anthropic.complete([Message.user("hi")], [], Map.put(base, :reasoning, :off))

      assert_received {:ant_body, body2}
      refute Map.has_key?(body2, "thinking")
      refute Map.has_key?(body2, "output_config")

      # extra_body overrides thinking and output_config.effort
      assert {:ok, _} =
               Anthropic.complete(
                 [Message.user("hi")],
                 [],
                 Map.merge(base, %{
                   reasoning: :high,
                   extra_body: %{
                     "thinking" => %{"type" => "enabled", "budget_tokens" => 4096},
                     "output_config" => %{"effort" => "low"}
                   }
                 })
               )

      assert_received {:ant_body, body3}
      assert body3["thinking"] == %{"type" => "enabled", "budget_tokens" => 4096}
      assert body3["output_config"]["effort"] == "low"

      # Invalid :reasoning fails before auth callback runs
      key_calls = :atomics.new(1, signed: false)

      assert {:error, %Error{kind: :invalid_request}} =
               Anthropic.complete(
                 [Message.user("hi")],
                 [],
                 Map.merge(base, %{
                   api_key: fn ->
                     :atomics.add_get(key_calls, 1, 1)
                     {:ok, "never"}
                   end,
                   reasoning: :bad
                 })
               )

      assert :atomics.get(key_calls, 1) == 0
    end

    test "OpenAI / xAI translates effort/summary and respects extra_body" do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:oai_body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
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
          })
        )
      end

      base = %{api_key: "sk-oai", model: "gpt-5.4", req_options: [plug: plug]}

      assert {:ok, _} =
               OpenAI.complete(
                 [Message.user("hi")],
                 [],
                 Map.put(base, :reasoning, %{effort: :xhigh, display: :summarized})
               )

      assert_received {:oai_body, body1}
      assert body1["reasoning"] == %{"effort" => "xhigh", "summary" => "auto"}

      assert {:ok, _} = XAI.complete([Message.user("hi")], [], Map.put(base, :reasoning, :off))
      assert_received {:oai_body, body2}
      assert body2["reasoning"] == %{"effort" => "none"}

      assert {:ok, _} =
               OpenAI.complete(
                 [Message.user("hi")],
                 [],
                 Map.merge(base, %{
                   reasoning: :high,
                   extra_body: %{"reasoning" => %{"effort" => "low", "summary" => "detailed"}}
                 })
               )

      assert_received {:oai_body, body3}
      assert body3["reasoning"] == %{"effort" => "low", "summary" => "detailed"}

      # Invalid :reasoning fails before auth callback
      key_calls = :atomics.new(1, signed: false)

      assert {:error, %Error{kind: :invalid_request}} =
               OpenAI.complete(
                 [Message.user("hi")],
                 [],
                 Map.merge(base, %{
                   api_key: fn ->
                     :atomics.add_get(key_calls, 1, 1)
                     {:ok, "never"}
                   end,
                   reasoning: :bad
                 })
               )

      assert :atomics.get(key_calls, 1) == 0
    end

    test "Gemini translates thinkingConfig and respects explicit generation_config" do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:gem_body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "candidates" => [
              %{
                "content" => %{"role" => "model", "parts" => [%{"text" => "ok"}]},
                "finishReason" => "STOP"
              }
            ],
            "usageMetadata" => %{"promptTokenCount" => 1, "candidatesTokenCount" => 1}
          })
        )
      end

      base = %{api_key: "gk-1", model: "gemini-3-flash", req_options: [plug: plug]}

      assert {:ok, _} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 Map.put(base, :reasoning, %{effort: :high, display: :summarized})
               )

      assert_received {:gem_body, body1}

      assert body1["generationConfig"]["thinkingConfig"] == %{
               "thinkingLevel" => "HIGH",
               "includeThoughts" => true
             }

      assert {:ok, _} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 Map.put(base, :reasoning, %{effort: :low, display: :omitted})
               )

      assert_received {:gem_body, body2}

      assert body2["generationConfig"]["thinkingConfig"] == %{
               "thinkingLevel" => "LOW",
               "includeThoughts" => false
             }

      assert {:ok, _} = Gemini.complete([Message.user("hi")], [], Map.put(base, :reasoning, :off))
      assert_received {:gem_body, body3}
      assert body3["generationConfig"]["thinkingConfig"] == %{"thinkingBudget" => 0}

      # Explicit generation_config.thinkingConfig takes precedence
      assert {:ok, _} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 Map.merge(base, %{
                   reasoning: :high,
                   generation_config: %{thinkingConfig: %{thinkingBudget: 2048}}
                 })
               )

      assert_received {:gem_body, body4}
      assert body4["generationConfig"]["thinkingConfig"] == %{"thinkingBudget" => 2048}
    end

    test "OpenAICompat sets reasoning_effort and Codex injects -c model_reasoning_effort" do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:compat_body, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "choices" => [
              %{
                "message" => %{"role" => "assistant", "content" => "ok"},
                "finish_reason" => "stop"
              }
            ]
          })
        )
      end

      compat_base = %{
        api_url: "http://localhost:11434",
        model: "qwen",
        req_options: [plug: plug]
      }

      assert {:ok, _} =
               OpenAICompat.complete(
                 [Message.user("hi")],
                 [],
                 Map.put(compat_base, :reasoning, :xhigh)
               )

      assert_received {:compat_body, cb1}
      assert cb1["reasoning_effort"] == "xhigh"

      assert {:ok, _} =
               OpenAICompat.complete(
                 [Message.user("hi")],
                 [],
                 Map.merge(compat_base, %{
                   reasoning: :high,
                   extra_body: %{"reasoning_effort" => "low"}
                 })
               )

      assert_received {:compat_body, cb2}
      assert cb2["reasoning_effort"] == "low"

      # Codex injects -c model_reasoning_effort unless explicitly overridden in config_overrides
      runner = fn _bin, args, _opts ->
        send(parent, {:codex_args, args})
        out_idx = Enum.find_index(args, &(&1 == "--output-last-message"))
        out_path = Enum.at(args, out_idx + 1)

        File.write!(
          out_path,
          Jason.encode!(%{stop_reason: "end_turn", text: "ok", tool_calls: []})
        )

        {"", 0}
      end

      assert {:ok, _} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 reasoning: :high,
                 command_runner: runner
               })

      assert_received {:codex_args, args1}
      assert ~s(model_reasoning_effort="high") in args1

      assert {:ok, _} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 reasoning: :high,
                 config_overrides: [~s(model_reasoning_effort="low")],
                 command_runner: runner
               })

      assert_received {:codex_args, args2}
      assert ~s(model_reasoning_effort="low") in args2
      refute ~s(model_reasoning_effort="high") in args2

      assert {:error, %Error{kind: :invalid_request}} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 reasoning: :invalid,
                 command_runner: runner
               })
    end

    test "Compactor strips top-level and provider-level :reasoning on summary calls" do
      parent = self()

      cfg =
        Config.from_opts(
          provider:
            {CaptureReasoningProvider, test_pid: parent, label: :summary, reasoning: :xhigh},
          reasoning: :high,
          max_tokens: 1_000,
          compaction: [reserve_tokens: 200, keep_recent_tokens: 50]
        )

      long = String.duplicate("word ", 1_200)

      state =
        State.init(cfg, [
          Message.user("Initial question"),
          Message.assistant(long),
          Message.user("Follow up"),
          Message.assistant("Recent reply")
        ])

      _compacted = Compactor.call(:before_completion, state)
      assert_received {:captured_reasoning, :summary, nil}
    end
  end

  describe "uniform streaming events (:thinking_delta and :tool_call_delta)" do
    test "Anthropic emits :tool_call_delta for client tool_use and skips server_tool_use" do
      parent = self()

      sse =
        [
          sse_ant("message_start", %{
            "message" => %{"usage" => %{"input_tokens" => 5, "output_tokens" => 0}}
          }),
          sse_ant("content_block_start", %{
            "index" => 0,
            "content_block" => %{
              "type" => "server_tool_use",
              "id" => "srv_1",
              "name" => "web_search",
              "input" => %{}
            }
          }),
          sse_ant("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"q":"x"})}
          }),
          sse_ant("content_block_stop", %{"index" => 0}),
          sse_ant("content_block_start", %{
            "index" => 1,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_1",
              "name" => "read",
              "input" => %{}
            }
          }),
          sse_ant("content_block_delta", %{
            "index" => 1,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":)}
          }),
          sse_ant("content_block_delta", %{
            "index" => 1,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("a.ex"})}
          }),
          sse_ant("content_block_stop", %{"index" => 1}),
          sse_ant("message_delta", %{
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{"output_tokens" => 10}
          }),
          sse_ant("message_stop", %{})
        ]
        |> Enum.join()

      plug = sse_plug(sse)

      assert {:ok, %{stop_reason: :tool_use}} =
               Anthropic.stream(
                 [Message.user("read a.ex")],
                 [],
                 %{
                   api_key: "sk-ant",
                   model: "claude-sonnet-5-5",
                   on_event: &send(parent, {:ev, &1}),
                   req_options: [plug: plug]
                 },
                 fn _ -> :ok end
               )

      assert_received {:ev,
                       {:tool_call_delta,
                        %{id: "toolu_1", index: 1, name: "read", arguments_delta: ""}}}

      assert_received {:ev,
                       {:tool_call_delta,
                        %{id: "toolu_1", index: 1, name: "read", arguments_delta: ~s({"path":)}}}

      assert_received {:ev,
                       {:tool_call_delta,
                        %{id: "toolu_1", index: 1, name: "read", arguments_delta: ~s("a.ex"})}}}

      refute_received {:ev, {:tool_call_delta, %{id: "srv_1"}}}
    end

    test "OpenAI emits :thinking_delta and :tool_call_delta during Responses streaming" do
      parent = self()

      sse =
        [
          sse_oai("response.reasoning_summary_text.delta", %{
            "type" => "response.reasoning_summary_text.delta",
            "delta" => "Thinking "
          }),
          sse_oai("response.reasoning_text.delta", %{
            "type" => "response.reasoning_text.delta",
            "delta" => "deeply."
          }),
          sse_oai("response.output_item.added", %{
            "type" => "response.output_item.added",
            "output_index" => 1,
            "item" => %{
              "id" => "fc_1",
              "call_id" => "call_1",
              "type" => "function_call",
              "name" => "echo",
              "arguments" => ""
            }
          }),
          sse_oai("response.function_call_arguments.delta", %{
            "type" => "response.function_call_arguments.delta",
            "item_id" => "fc_1",
            "output_index" => 1,
            "delta" => ~s({"text":"hi"})
          }),
          sse_oai("response.completed", %{
            "type" => "response.completed",
            "response" => %{
              "id" => "resp_1",
              "status" => "completed",
              "output" => [
                %{
                  "id" => "fc_1",
                  "call_id" => "call_1",
                  "type" => "function_call",
                  "name" => "echo",
                  "arguments" => ~s({"text":"hi"})
                }
              ],
              "usage" => %{"input_tokens" => 5, "output_tokens" => 5}
            }
          })
        ]
        |> Enum.join()

      plug = sse_plug(sse)

      assert {:ok, %{stop_reason: :tool_use}} =
               OpenAI.stream(
                 [Message.user("hi")],
                 [],
                 %{
                   api_key: "sk-oai",
                   model: "gpt-5.4",
                   on_event: &send(parent, {:ev, &1}),
                   req_options: [plug: plug]
                 },
                 fn _ -> :ok end
               )

      assert_received {:ev, {:thinking_delta, "Thinking "}}
      assert_received {:ev, {:thinking_delta, "deeply."}}

      assert_received {:ev,
                       {:tool_call_delta,
                        %{id: "call_1", index: 1, name: "echo", arguments_delta: ""}}}

      assert_received {:ev,
                       {:tool_call_delta,
                        %{
                          id: "call_1",
                          index: 1,
                          name: "echo",
                          arguments_delta: ~s({"text":"hi"})
                        }}}
    end

    test "Gemini emits :thinking_delta and :tool_call_delta during SSE streaming" do
      parent = self()

      sse =
        "data: " <>
          Jason.encode!(%{
            "candidates" => [
              %{
                "content" => %{
                  "role" => "model",
                  "parts" => [
                    %{"text" => "Plan step 1", "thought" => true},
                    %{
                      "functionCall" => %{
                        "id" => "gcall_1",
                        "name" => "echo",
                        "args" => %{"text" => "yo"}
                      }
                    }
                  ]
                },
                "finishReason" => "STOP"
              }
            ],
            "usageMetadata" => %{"promptTokenCount" => 3, "candidatesTokenCount" => 4}
          }) <> "\n\n"

      assert {:ok, %{stop_reason: :tool_use}} =
               Gemini.stream(
                 [Message.user("hi")],
                 [],
                 %{
                   api_key: "gk-1",
                   model: "gemini-3-flash",
                   on_event: &send(parent, {:ev, &1}),
                   req_options: [plug: sse_plug(sse)]
                 },
                 fn _ -> :ok end
               )

      assert_received {:ev, {:thinking_delta, "Plan step 1"}}

      assert_received {:ev,
                       {:tool_call_delta,
                        %{
                          id: "gcall_1",
                          index: 0,
                          name: "echo",
                          arguments_delta: ~s({"text":"yo"})
                        }}}
    end

    test "OpenAICompat emits :thinking_delta and :tool_call_delta and suppresses events on malformed chunks" do
      parent = self()

      sse =
        "data: " <>
          Jason.encode!(%{
            "choices" => [
              %{
                "delta" => %{
                  "reasoning_content" => "Step A",
                  "content" => [%{"type" => "thinking", "thinking" => "Step B"}],
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => "call_c1",
                      "type" => "function",
                      "function" => %{"name" => "echo", "arguments" => ~s({"text":)}
                    }
                  ]
                }
              }
            ]
          }) <>
          "\n\ndata: " <>
          Jason.encode!(%{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{"index" => 0, "function" => %{"arguments" => ~s("ok"})}}
                  ]
                },
                "finish_reason" => "tool_calls"
              }
            ]
          }) <> "\n\ndata: [DONE]\n\n"

      assert {:ok, %{stop_reason: :tool_use}} =
               OpenAICompat.stream(
                 [Message.user("hi")],
                 [],
                 %{
                   api_url: "http://localhost:11434",
                   model: "deepseek-r1",
                   on_event: &send(parent, {:ev, &1}),
                   req_options: [plug: sse_plug(sse)]
                 },
                 fn _ -> :ok end
               )

      assert_received {:ev, {:thinking_delta, "Step A"}}
      assert_received {:ev, {:thinking_delta, "Step B"}}

      assert_received {:ev,
                       {:tool_call_delta,
                        %{id: "call_c1", index: 0, name: "echo", arguments_delta: ~s({"text":)}}}

      assert_received {:ev,
                       {:tool_call_delta,
                        %{id: "call_c1", index: 0, name: "echo", arguments_delta: ~s("ok"})}}}

      # Malformed tool_calls sibling on the same chunk must NOT leak :thinking_delta
      bad_sse =
        "data: " <>
          Jason.encode!(%{
            "choices" => [
              %{
                "delta" => %{
                  "reasoning_content" => "should-not-emit",
                  "tool_calls" => "not-a-list"
                }
              }
            ]
          }) <> "\n\ndata: [DONE]\n\n"

      assert {:error, %Error{kind: :protocol_error}} =
               OpenAICompat.stream(
                 [Message.user("hi")],
                 [],
                 %{
                   api_url: "http://localhost:11434",
                   model: "deepseek-r1",
                   on_event: &send(parent, {:bad_ev, &1}),
                   req_options: [plug: sse_plug(bad_sse)]
                 },
                 fn _ -> :ok end
               )

      refute_received {:bad_ev, _}
    end
  end

  describe "turn lifecycle (:turn_start / :turn_end) and :tool_update + Core.Bash streaming" do
    test "emits :turn_start and :turn_end with per-turn usage diff and nil stop_reason on halted turn" do
      parent = self()

      {:ok, pid} =
        TestProvider.start_link([
          {:ok,
           %{
             stop_reason: :tool_use,
             messages: [
               Message.assistant_blocks([
                 %{type: "tool_use", id: "t1", name: "echo", input: %{"text" => "hello"}}
               ])
             ],
             usage: %{input_tokens: 10, output_tokens: 4}
           }},
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("Done")],
             usage: %{input_tokens: 20, output_tokens: 6}
           }}
        ])

      assert {:ok, result} =
               Alloy.run("Run echo",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [Alloy.Test.EchoTool],
                 on_event: &send(parent, {:ev, &1})
               )

      assert result.status == :completed

      events = collect_events()
      turn_events = Enum.filter(events, &(&1.event in [:turn_start, :turn_end]))

      assert [
               %{event: :turn_start, turn: 1, payload: %{turn: 1}},
               %{
                 event: :turn_end,
                 turn: 1,
                 payload: %{
                   turn: 1,
                   status: :running,
                   stop_reason: :tool_use,
                   usage: %Usage{input_tokens: 10, output_tokens: 4}
                 }
               },
               %{event: :turn_start, turn: 2, payload: %{turn: 2}},
               %{
                 event: :turn_end,
                 turn: 2,
                 payload: %{
                   turn: 2,
                   status: :completed,
                   stop_reason: :end_turn,
                   usage: %Usage{input_tokens: 20, output_tokens: 6}
                 }
               }
             ] = turn_events

      # When turn 2 halts in :before_completion middleware, stop_reason is nil (never turn 1's :tool_use)
      {:ok, pid2} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "t1", name: "echo", input: %{"text" => "hi"}}])
        ])

      assert {:error, halted} =
               Alloy.run("Run echo",
                 provider: {TestProvider, agent_pid: pid2},
                 tools: [Alloy.Test.EchoTool],
                 middleware: [HaltTurn2Middleware],
                 on_event: &send(parent, {:ev, &1})
               )

      assert halted.status == :halted
      halted_events = collect_events()
      t2_end = Enum.find(halted_events, &(&1.event == :turn_end and &1.turn == 2))
      assert t2_end.payload.status == :halted
      assert t2_end.payload.stop_reason == nil
      assert t2_end.payload.usage == %Usage{}
    end

    test "marshals :tool_update strictly on the caller process between :tool_start and :tool_end" do
      caller = self()

      streaming_tool = %Inline{
        name: "streamer",
        description: "Emits incremental progress",
        input_schema: %{type: "object", properties: %{}},
        execute: fn _input, context ->
          context.on_tool_update.("part-1")
          Process.sleep(15)
          context.on_tool_update.("part-2")
          {:ok, "done"}
        end
      }

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "call_s1", name: "streamer", input: %{}}]),
          TestProvider.text_response("finished")
        ])

      assert {:ok, _} =
               Alloy.run("stream it",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [streaming_tool],
                 on_event: fn ev -> send(caller, {:ev, {self(), ev}}) end
               )

      delivered = collect_pid_events()
      assert Enum.all?(delivered, fn {pid, _ev} -> pid == caller end)

      tool_events =
        delivered
        |> Enum.map(fn {_pid, ev} -> ev end)
        |> Enum.filter(&(&1.event in [:tool_start, :tool_update, :tool_end]))

      assert [
               %{event: :tool_start, seq: s0, payload: %{id: "call_s1", name: "streamer"}},
               %{
                 event: :tool_update,
                 seq: s1,
                 payload: %{id: "call_s1", name: "streamer", chunk: "part-1", start_event_seq: s0}
               },
               %{
                 event: :tool_update,
                 seq: s2,
                 payload: %{id: "call_s1", name: "streamer", chunk: "part-2", start_event_seq: s0}
               },
               %{
                 event: :tool_end,
                 seq: s3,
                 payload: %{id: "call_s1", name: "streamer", start_event_seq: s0}
               }
             ] = tool_events

      assert s0 < s1 and s1 < s2 and s2 < s3
    end

    test "Core.Bash streams :tool_update on caller process and sends full pre-truncation bytes to :bash_on_output" do
      caller = self()
      raw_chunks_agent = start_supervised!({Agent, fn -> [] end})

      # Print > 35KB so Core.Bash's 8KB head + 20KB tail truncation activates, while
      # :bash_on_output still receives every raw byte pre-truncation.
      cmd = "python3 -c 'import sys; sys.stdout.write(\"A\" * 40000); sys.stdout.flush()'"

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "bash_1", name: "bash", input: %{"command" => cmd}}
          ]),
          TestProvider.text_response("done")
        ])

      assert {:ok, result} =
               Alloy.run("run bash",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [Bash],
                 context: %{
                   bash_restricted: false,
                   bash_on_output: fn chunk ->
                     Agent.update(raw_chunks_agent, &[chunk | &1])
                   end
                 },
                 on_event: fn ev -> send(caller, {:ev, {self(), ev}}) end
               )

      assert result.status == :completed
      delivered = collect_pid_events()
      assert Enum.all?(delivered, fn {p, _ev} -> p == caller end)

      updates =
        delivered
        |> Enum.map(&elem(&1, 1))
        |> Enum.filter(&(&1.event == :tool_update))

      assert updates != []
      assert Enum.all?(updates, &(&1.payload.name == "bash" and &1.payload.id == "bash_1"))

      total_raw =
        raw_chunks_agent
        |> Agent.get(&Enum.reverse/1)
        |> IO.iodata_to_binary()

      assert byte_size(total_raw) == 40_000

      # A raising :bash_on_output callback is rescued and logged once without failing bash.
      log =
        capture_log(fn ->
          assert {:ok, out} =
                   Bash.execute(
                     %{"command" => "echo one; echo two"},
                     %{
                       bash_restricted: false,
                       bash_on_output: fn _chunk -> raise "spill disk full" end
                     }
                   )

          assert out =~ "one"
          assert out =~ "two"
        end)

      assert log =~ ":bash_on_output callback failed"
    end
  end

  defp sse_plug(sse) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse)
    end
  end

  defp sse_ant(event, payload), do: "event: #{event}\ndata: #{Jason.encode!(payload)}\n\n"
  defp sse_oai(event, payload), do: "event: #{event}\ndata: #{Jason.encode!(payload)}\n\n"

  defp collect_events(acc \\ []) do
    receive do
      {:ev, ev} -> collect_events([ev | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_pid_events(acc \\ []) do
    receive do
      {:ev, {pid, ev}} -> collect_pid_events([{pid, ev} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
