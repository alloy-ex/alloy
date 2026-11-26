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

  defmodule RaiseAfterToolCallMiddleware do
    @behaviour Alloy.Middleware

    @impl true
    def call(:after_tool_call, %{config: %{context: %{current_tool_call: %{name: "fast_fail"}}}}) do
      raise "after_tool_boom"
    end

    def call(_hook, state), do: state
  end

  defmodule RaiseBeforeCompletionMiddleware do
    @behaviour Alloy.Middleware

    @impl true
    def call(:before_completion, _state), do: raise("turn_exploded")
    def call(_hook, state), do: state
  end

  defmodule RaiseAfterCompletionMiddleware do
    @behaviour Alloy.Middleware

    @impl true
    def call(:after_completion, _state), do: raise("after_completion_boom")
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

      # When both provider (with its own :reasoning) and top-level :reasoning are passed to
      # State.prepare/2 in the same call, the new provider's explicit :reasoning is preserved.
      both =
        State.prepare(state,
          provider: {TestProvider, reasoning: :low},
          reasoning: :high
        )

      assert both.config.reasoning == %{effort: :high, display: nil}
      assert both.config.provider_config.reasoning == %{effort: :low, display: nil}
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

      # :off explicitly disables thinking on Anthropic, while nil omits thinking
      assert {:ok, _} =
               Anthropic.complete([Message.user("hi")], [], Map.put(base, :reasoning, :off))

      assert_received {:ant_body, body2}
      assert body2["thinking"] == %{"type" => "disabled"}
      refute Map.has_key?(body2, "output_config")

      assert {:ok, _} =
               Anthropic.complete([Message.user("hi")], [], Map.put(base, :reasoning, nil))

      assert_received {:ant_body, body_nil}
      refute Map.has_key?(body_nil, "thinking")
      refute Map.has_key?(body_nil, "output_config")

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

      # Changing :reasoning on a persistent Codex session invalidates session_scope (starts fresh)
      thread_runner = fn _bin, args, _opts ->
        send(parent, {:codex_sess_args, args})
        out_idx = Enum.find_index(args, &(&1 == "--output-last-message"))
        out_path = Enum.at(args, out_idx + 1)

        File.write!(
          out_path,
          Jason.encode!(%{stop_reason: "end_turn", text: "ok", tool_calls: []})
        )

        {Jason.encode!(%{"type" => "thread.started", "thread_id" => "thr_1"}) <> "\n", 0}
      end

      assert {:ok, r1} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 reasoning: :high,
                 persist_session: true,
                 workdir: System.tmp_dir!(),
                 command_runner: thread_runner
               })

      assert_received {:codex_sess_args, _}

      assert {:ok, r2} =
               Codex.complete(
                 [Message.user("hi"), hd(r1.messages), Message.user("again")],
                 [],
                 %{
                   model: "gpt-5.4",
                   reasoning: :low,
                   persist_session: true,
                   workdir: System.tmp_dir!(),
                   provider_state: r1.provider_state,
                   command_runner: thread_runner
                 }
               )

      assert_received {:codex_sess_args, sess_args2}
      refute "resume" in sess_args2
      assert r2.response_metadata.session.mode == :fresh
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

      # Print > 35KB using portable POSIX tools so Core.Bash's 8KB head + 20KB tail
      # truncation activates, while :bash_on_output still receives every raw byte.
      cmd = "head -c 40000 /dev/zero | tr '\\0' A"

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

    test "Core.Bash preserves multibyte UTF-8 split across port chunks in :tool_update" do
      caller = self()

      # Write the 3-byte UTF-8 sequence for "€" (E2 82 AC) across separate writes.
      cmd = "printf '\\342\\202'; sleep 0.05; printf '\\254'"

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "bash_utf8", name: "bash", input: %{"command" => cmd}}
          ]),
          TestProvider.text_response("done")
        ])

      assert {:ok, result} =
               Alloy.run("utf8",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [Bash],
                 context: %{bash_restricted: false},
                 on_event: fn ev -> send(caller, {:ev, ev}) end
               )

      assert result.status == :completed

      updates_text =
        collect_events()
        |> Enum.filter(&(&1.event == :tool_update))
        |> Enum.map_join("", & &1.payload.chunk)

      assert updates_text == "€"
    end

    test "blocked :bash_on_output does not prevent shell cleanup on caller death or timeout" do
      parent = self()
      gate = make_ref()

      # 1. Caller death while :bash_on_output is blocked kills the shell process promptly.
      blocker =
        spawn(fn ->
          receive do
            {:release, ^gate} -> :ok
          end
        end)

      caller_pid =
        spawn(fn ->
          Bash.execute(
            %{"command" => "echo $$; sleep 30", "timeout" => 30_000},
            %{
              bash_restricted: false,
              bash_on_output: fn chunk ->
                send(parent, {:bash_chunk, chunk})
                ref = Process.monitor(blocker)

                receive do
                  {:DOWN, ^ref, :process, ^blocker, _} -> :ok
                end
              end
            }
          )
        end)

      assert_receive {:bash_chunk, pid_chunk}, 2_000
      shell_pid = pid_chunk |> String.trim() |> String.to_integer()
      Process.exit(caller_pid, :kill)

      assert wait_until_dead(shell_pid, 1_500)
      send(blocker, {:release, gate})

      # 2. Timeout while :bash_on_output is blocked still terminates promptly.
      blocker2 =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      started = System.monotonic_time(:millisecond)

      assert {:error, msg} =
               Bash.execute(
                 %{"command" => "echo $$; sleep 30", "timeout" => 120},
                 %{
                   bash_restricted: false,
                   bash_on_output: fn chunk ->
                     send(parent, {:bash_timeout_chunk, chunk})
                     ref = Process.monitor(blocker2)

                     receive do
                       {:DOWN, ^ref, :process, ^blocker2, _} -> :ok
                     end
                   end
                 }
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert msg =~ "timed out"
      assert elapsed < 1_000

      assert_receive {:bash_timeout_chunk, pid_chunk2}, 1_000
      shell_pid2 = pid_chunk2 |> String.trim() |> String.to_integer()
      assert wait_until_dead(shell_pid2, 1_500)
      send(blocker2, :stop)
    end

    test "Executor enforces tool_timeout independently of slow :on_event callbacks and keeps mailbox clean on timeout/abort" do
      parent = self()

      # 1. Slow on_event (200ms) must NOT delay tool_timeout (40ms) killing the tool before
      #    an observable side effect at 100ms.
      side_effect_flag = :atomics.new(1, signed: false)

      slow_side_effect_tool = %Inline{
        name: "side_effect",
        description: "Streams then performs a side effect",
        input_schema: %{type: "object", properties: %{}},
        execute: fn _input, context ->
          if fun = Map.get(context, :on_tool_update), do: fun.("tick")
          Process.sleep(100)
          :atomics.put(side_effect_flag, 1, 1)
          {:ok, "too late"}
        end
      }

      {:ok, pid1} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "c_slow", name: "side_effect", input: %{}}]),
          TestProvider.text_response("after timeout")
        ])

      assert {:ok, _} =
               Alloy.run("go",
                 provider: {TestProvider, agent_pid: pid1},
                 tools: [slow_side_effect_tool],
                 tool_timeout: 40,
                 on_event: fn
                   %{event: :tool_update} = ev ->
                     send(parent, {:slow_cb_ev, ev})
                     Process.sleep(200)

                   ev ->
                     send(parent, {:slow_cb_ev, ev})
                 end
               )

      assert :atomics.get(side_effect_flag, 1) == 0
      # Flush expected test notifications, then verify zero leaked runtime/timer/monitor messages.
      drain_tagged(:slow_cb_ev)
      refute_receive _, 80

      # 2. Spawning a child that emits late updates after tool_timeout must not leak into mailbox
      #    and must never emit :tool_update after :tool_end.
      late_update_tool = %Inline{
        name: "late_child",
        description: "Spawns child that keeps sending updates",
        input_schema: %{type: "object", properties: %{}},
        execute: fn _input, context ->
          fun = Map.get(context, :on_tool_update)

          spawn(fn ->
            Enum.each(1..5, fn i ->
              if fun, do: fun.("late-#{i}")
              Process.sleep(20)
            end)
          end)

          Process.sleep(500)
          {:ok, "never"}
        end
      }

      {:ok, pid2} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "c_late", name: "late_child", input: %{}}]),
          TestProvider.text_response("done")
        ])

      assert {:ok, _} =
               Alloy.run("go",
                 provider: {TestProvider, agent_pid: pid2},
                 tools: [late_update_tool],
                 tool_timeout: 35,
                 on_event: &send(parent, {:late_ev, &1})
               )

      late_events = drain_tagged(:late_ev)
      end_idx = Enum.find_index(late_events, &(&1.event == :tool_end))
      assert is_integer(end_idx)
      refute Enum.any?(Enum.drop(late_events, end_idx + 1), &(&1.event == :tool_update))
      refute_receive _, 120

      # 3. Throwing from :tool_update or raising in :after_tool_call cleans up running siblings
      #    and leaves zero monitor/timer/update messages in the caller mailbox.
      sibling_alive = :atomics.new(1, signed: false)

      throw_tool = %Inline{
        name: "throw_trigger",
        description: "Emits update",
        input_schema: %{type: "object", properties: %{}},
        execute: fn _input, context ->
          if fun = Map.get(context, :on_tool_update), do: fun.("boom")
          Process.sleep(200)
          {:ok, "ok"}
        end
      }

      sibling_tool = %Inline{
        name: "sibling",
        description: "Sleeps",
        input_schema: %{type: "object", properties: %{}},
        execute: fn _input, _context ->
          Process.sleep(150)
          :atomics.put(sibling_alive, 1, 1)
          {:ok, "ok"}
        end
      }

      {:ok, pid3} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t_throw", name: "throw_trigger", input: %{}},
            %{id: "t_sib", name: "sibling", input: %{}}
          ])
        ])

      assert catch_throw(
               Alloy.run("go",
                 provider: {TestProvider, agent_pid: pid3},
                 tools: [throw_tool, sibling_tool],
                 tool_timeout: 200,
                 on_event: fn
                   %{event: :tool_update} -> throw(:abort_ui)
                   _ -> :ok
                 end
               )
             ) == :abort_ui

      refute_receive _, 250
      assert :atomics.get(sibling_alive, 1) == 0

      # Raising in :after_tool_call while sibling runs leaves mailbox clean too.
      fast_fail = %Inline{
        name: "fast_fail",
        description: "Fast",
        input_schema: %{type: "object", properties: %{}},
        execute: fn _input, _ctx -> {:ok, "fast"} end
      }

      {:ok, pid4} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{id: "t_ff", name: "fast_fail", input: %{}},
            %{id: "t_sib2", name: "sibling", input: %{}}
          ])
        ])

      assert_raise RuntimeError, "after_tool_boom", fn ->
        Alloy.run("go",
          provider: {TestProvider, agent_pid: pid4},
          tools: [fast_fail, sibling_tool],
          middleware: [RaiseAfterToolCallMiddleware],
          tool_timeout: 200
        )
      end

      refute_receive _, 250
      assert :atomics.get(sibling_alive, 1) == 0
    end

    test "parallel batch with tool_concurrency < batch size keeps :tool_update inside each call's window" do
      caller = self()

      worker_tool = %Inline{
        name: "work",
        description: "Work",
        input_schema: %{type: "object", properties: %{n: %{type: "integer"}}},
        execute: fn %{"n" => n}, context ->
          if fun = Map.get(context, :on_tool_update), do: fun.("u-#{n}")
          Process.sleep(10)
          {:ok, "ok-#{n}"}
        end
      }

      calls = for n <- 1..4, do: %{id: "c_#{n}", name: "work", input: %{"n" => n}}

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response(calls),
          TestProvider.text_response("all done")
        ])

      assert {:ok, %{status: :completed}} =
               Alloy.run("run 4",
                 provider: {TestProvider, agent_pid: pid},
                 tools: [worker_tool],
                 tool_concurrency: 2,
                 on_event: &send(caller, {:ev, &1})
               )

      events = collect_events()

      for n <- 1..4 do
        id = "c_#{n}"
        start_ev = Enum.find(events, &(&1.event == :tool_start and &1.payload.id == id))
        update_ev = Enum.find(events, &(&1.event == :tool_update and &1.payload.id == id))
        end_ev = Enum.find(events, &(&1.event == :tool_end and &1.payload.id == id))

        assert start_ev.seq < update_ev.seq
        assert update_ev.seq < end_ev.seq
        assert update_ev.payload.start_event_seq == start_ev.seq
        assert end_ev.payload.start_event_seq == start_ev.seq
      end
    end

    test "subscriber-aware chunks_emitted?, OpenAI malformed tool header validation, and terminal :turn_end limits" do
      parent = self()

      # 1. Without :on_event subscriber, a transient failure after a tool_call_delta still retries.
      attempts = :atomics.new(1, signed: false)

      flaky_oai_plug = fn conn ->
        n = :atomics.add_get(attempts, 1, 1)

        sse =
          if n == 1 do
            sse_oai("response.output_item.added", %{
              "type" => "response.output_item.added",
              "output_index" => 0,
              "item" => %{
                "id" => "fc_1",
                "call_id" => "call_1",
                "type" => "function_call",
                "name" => "echo",
                "arguments" => ""
              }
            }) <>
              sse_oai("response.failed", %{
                "type" => "response.failed",
                "response" => %{
                  "status" => "failed",
                  "error" => %{"code" => "server_error", "message" => "transient"}
                }
              })
          else
            sse_oai("response.output_text.delta", %{
              "type" => "response.output_text.delta",
              "delta" => "recovered"
            }) <>
              sse_oai("response.completed", %{
                "type" => "response.completed",
                "response" => %{
                  "id" => "resp_ok",
                  "status" => "completed",
                  "output" => [
                    %{
                      "type" => "message",
                      "role" => "assistant",
                      "content" => [%{"type" => "output_text", "text" => "recovered"}]
                    }
                  ],
                  "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
                }
              })
          end

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end

      assert {:ok, %{text: "recovered"}} =
               Alloy.stream("hi", fn _ -> :ok end,
                 provider:
                   {OpenAI,
                    api_key: "sk-oai", model: "gpt-5.4", req_options: [plug: flaky_oai_plug]},
                 max_retries: 1,
                 retry_backoff_ms: 0
               )

      assert :atomics.get(attempts, 1) == 2

      # 2. Malformed OpenAI function_call header does NOT emit :tool_call_delta and still retries
      #    even when :on_event IS subscribed.
      bad_attempts = :atomics.new(1, signed: false)

      malformed_oai_plug = fn conn ->
        n = :atomics.add_get(bad_attempts, 1, 1)

        sse =
          if n == 1 do
            sse_oai("response.output_item.added", %{
              "type" => "response.output_item.added",
              "output_index" => -2,
              "item" => %{
                "id" => %{},
                "type" => "function_call",
                "name" => []
              }
            }) <>
              sse_oai("response.failed", %{
                "type" => "response.failed",
                "response" => %{
                  "status" => "failed",
                  "error" => %{"code" => "server_error", "message" => "transient"}
                }
              })
          else
            sse_oai("response.completed", %{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp_ok2",
                "status" => "completed",
                "output" => [
                  %{
                    "type" => "message",
                    "role" => "assistant",
                    "content" => [%{"type" => "output_text", "text" => "clean"}]
                  }
                ],
                "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
              }
            })
          end

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end

      assert {:ok, %{text: "clean"}} =
               Alloy.stream("hi", fn _ -> :ok end,
                 provider:
                   {OpenAI,
                    api_key: "sk-oai", model: "gpt-5.4", req_options: [plug: malformed_oai_plug]},
                 max_retries: 1,
                 retry_backoff_ms: 0,
                 on_event: &send(parent, {:mal_ev, &1})
               )

      assert :atomics.get(bad_attempts, 1) == 2
      mal_events = drain_tagged(:mal_ev)
      refute Enum.any?(mal_events, &(&1.event == :tool_call_delta))
      assert Enum.any?(mal_events, &(&1.event == :turn_start))
      assert Enum.any?(mal_events, &(&1.event == :turn_end and &1.payload.status == :completed))

      # 3. max_turns: 1 reports final :turn_end status :max_turns (not :running).
      {:ok, max_pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "t1", name: "echo", input: %{"text" => "hi"}}])
        ])

      assert {:ok, max_res} =
               Alloy.run("loop",
                 provider: {TestProvider, agent_pid: max_pid},
                 tools: [Alloy.Test.EchoTool],
                 max_turns: 1,
                 on_event: &send(parent, {:max_ev, &1})
               )

      assert max_res.status == :max_turns
      max_events = drain_tagged(:max_ev)

      assert [%{event: :turn_end, payload: %{status: :max_turns}}] =
               Enum.filter(max_events, &(&1.event == :turn_end))

      # 4. Exception during turn still emits paired :turn_end (status: :error) before re-raising.
      {:ok, err_pid} = TestProvider.start_link([TestProvider.text_response("never")])

      assert_raise RuntimeError, "turn_exploded", fn ->
        Alloy.run("boom",
          provider: {TestProvider, agent_pid: err_pid},
          middleware: [RaiseBeforeCompletionMiddleware],
          on_event: &send(parent, {:boom_ev, &1})
        )
      end

      boom_events = drain_tagged(:boom_ev)
      assert Enum.any?(boom_events, &(&1.event == :turn_start and &1.turn == 1))
      assert Enum.any?(boom_events, &(&1.event == :turn_end and &1.payload.status == :error))

      # 5. Post-response exception (:after_completion) preserves accounted stop_reason and usage.
      {:ok, post_err_pid} =
        TestProvider.start_link([
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant("done")],
             usage: %{input_tokens: 7, output_tokens: 3}
           }}
        ])

      assert_raise RuntimeError, "after_completion_boom", fn ->
        Alloy.run("go",
          provider: {TestProvider, agent_pid: post_err_pid},
          middleware: [RaiseAfterCompletionMiddleware],
          on_event: &send(parent, {:post_boom_ev, &1})
        )
      end

      post_boom_events = drain_tagged(:post_boom_ev)

      assert [
               %{
                 event: :turn_end,
                 payload: %{
                   turn: 1,
                   status: :error,
                   stop_reason: :end_turn,
                   usage: %Alloy.Usage{input_tokens: 7, output_tokens: 3}
                 }
               }
             ] = Enum.filter(post_boom_events, &(&1.event == :turn_end))
    end

    test "OpenAI malformed interim tool header with valid response.completed succeeds; OpenAICompat malformed id suppresses delta and retries" do
      parent = self()

      # 1. OpenAI Responses: malformed interim function_call header + valid response.completed
      #    must succeed (with or without :on_event) without emitting invalid :tool_call_delta.
      quirky_oai_plug =
        sse_plug(
          sse_oai("response.output_item.added", %{
            "type" => "response.output_item.added",
            "output_index" => -1,
            "item" => %{"id" => %{}, "type" => "function_call", "name" => ""}
          }) <>
            sse_oai("response.function_call_arguments.delta", %{
              "type" => "response.function_call_arguments.delta",
              "output_index" => -1,
              "delta" => "{}"
            }) <>
            sse_oai("response.completed", %{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp_quirky",
                "status" => "completed",
                "output" => [
                  %{
                    "type" => "message",
                    "role" => "assistant",
                    "content" => [%{"type" => "output_text", "text" => "still valid"}]
                  }
                ],
                "usage" => %{"input_tokens" => 2, "output_tokens" => 2}
              }
            })
        )

      assert {:ok, %{text: "still valid"}} =
               Alloy.stream("hi", fn _ -> :ok end,
                 provider:
                   {OpenAI,
                    api_key: "sk-oai", model: "gpt-5.4", req_options: [plug: quirky_oai_plug]},
                 on_event: &send(parent, {:quirky_ev, &1})
               )

      quirky_events = drain_tagged(:quirky_ev)
      refute Enum.any?(quirky_events, &(&1.event == :tool_call_delta))

      assert {:ok, %{text: "still valid"}} =
               Alloy.stream("hi", fn _ -> :ok end,
                 provider:
                   {OpenAI,
                    api_key: "sk-oai", model: "gpt-5.4", req_options: [plug: quirky_oai_plug]}
               )

      # 2. Chat Completions (OpenAIStream): malformed non-string id in tool header must NOT emit
      #    an invalid :tool_call_delta and must still retry on subsequent transient server_error.
      compat_attempts = :atomics.new(1, signed: false)

      flaky_compat_plug = fn conn ->
        n = :atomics.add_get(compat_attempts, 1, 1)

        sse =
          if n == 1 do
            "data: " <>
              Jason.encode!(%{
                "choices" => [
                  %{
                    "index" => 0,
                    "delta" => %{
                      "tool_calls" => [
                        %{
                          "index" => 0,
                          "id" => %{},
                          "function" => %{"name" => "echo", "arguments" => ""}
                        }
                      ]
                    }
                  }
                ]
              }) <>
              "\n\n" <>
              "data: " <>
              Jason.encode!(%{
                "error" => %{"type" => "server_error", "message" => "transient"}
              }) <> "\n\n"
          else
            "data: " <>
              Jason.encode!(%{
                "choices" => [
                  %{"index" => 0, "delta" => %{"content" => "recovered"}, "finish_reason" => nil}
                ]
              }) <>
              "\n\n" <>
              "data: " <>
              Jason.encode!(%{
                "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
                "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
              }) <> "\n\ndata: [DONE]\n\n"
          end

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end

      assert {:ok, %{text: "recovered"}} =
               Alloy.stream("hi", fn _ -> :ok end,
                 provider:
                   {OpenAICompat,
                    api_url: "https://compat.example/v1",
                    api_key: "sk-compat",
                    model: "qwen3",
                    req_options: [plug: flaky_compat_plug]},
                 max_retries: 1,
                 retry_backoff_ms: 0,
                 on_event: &send(parent, {:compat_ev, &1})
               )

      assert :atomics.get(compat_attempts, 1) == 2
      compat_events = drain_tagged(:compat_ev)
      refute Enum.any?(compat_events, &(&1.event == :tool_call_delta))
    end

    test "Executor closes per-call update alias before draining sustained child producers and gates :on_tool_update on subscriber" do
      parent = self()

      # 1. Without :on_event subscriber, :on_tool_update is not injected into tool context.
      no_sub_tool = %Inline{
        name: "check_ctx",
        description: "Checks on_tool_update presence",
        input_schema: %{type: "object", properties: %{}},
        execute: fn _input, context ->
          send(parent, {:has_update_cb, Map.has_key?(context, :on_tool_update)})
          {:ok, "ok"}
        end
      }

      {:ok, pid0} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "c0", name: "check_ctx", input: %{}}]),
          TestProvider.text_response("done")
        ])

      assert {:ok, %{status: :completed}} =
               Alloy.run("go", provider: {TestProvider, agent_pid: pid0}, tools: [no_sub_tool])

      assert_received {:has_update_cb, false}

      # 2. A surviving child process spamming on_tool_update every 5ms after tool return
      #    cannot keep finish/3 or the run alive indefinitely.
      stop_spammer = :atomics.new(1, signed: false)

      spammer_tool = %Inline{
        name: "spammer",
        description: "Spawns persistent updater",
        input_schema: %{type: "object", properties: %{}},
        execute: fn _input, context ->
          fun = Map.fetch!(context, :on_tool_update)

          child =
            spawn(fn ->
              Stream.repeatedly(fn -> :tick end)
              |> Enum.reduce_while(:ok, fn :tick, :ok ->
                if :atomics.get(stop_spammer, 1) == 1 do
                  {:halt, :ok}
                else
                  fun.("spam")
                  Process.sleep(5)
                  {:cont, :ok}
                end
              end)
            end)

          send(parent, {:spammer_child, child})
          Process.sleep(15)
          {:ok, "done"}
        end
      }

      {:ok, pid1} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "c_spam", name: "spammer", input: %{}}]),
          TestProvider.text_response("finished")
        ])

      started_at = System.monotonic_time(:millisecond)

      assert {:ok, %{status: :completed, text: "finished"}} =
               Alloy.run("go",
                 provider: {TestProvider, agent_pid: pid1},
                 tools: [spammer_tool],
                 timeout_ms: 500,
                 on_event: fn
                   %{event: :tool_update} = ev ->
                     send(parent, {:spam_ev, ev})
                     Process.sleep(10)

                   ev ->
                     send(parent, {:spam_ev, ev})
                 end
               )

      elapsed = System.monotonic_time(:millisecond) - started_at
      :atomics.put(stop_spammer, 1, 1)
      assert_receive {:spammer_child, child_pid}, 1_000
      assert elapsed < 400

      spam_events = drain_tagged(:spam_ev)
      end_idx = Enum.find_index(spam_events, &(&1.event == :tool_end))
      assert is_integer(end_idx)
      refute Enum.any?(Enum.drop(spam_events, end_idx + 1), &(&1.event == :tool_update))
      refute_receive _, 80
      Process.exit(child_pid, :kill)
    end

    test "Core.Bash preserves exit status on slow :bash_on_output, bounds high-volume backpressure, and cleans up worker on crash" do
      parent = self()

      # 1. Slow :bash_on_output on a fast-exiting command must preserve exit status 0
      #    and complete within the short flush grace window (not turn into a timeout).
      started = System.monotonic_time(:millisecond)

      assert {:ok, out} =
               Bash.execute(
                 %{"command" => "printf 'hello\\n'", "timeout" => 5_000},
                 %{
                   bash_restricted: false,
                   bash_on_output: fn _chunk ->
                     send(parent, {:slow_worker_pid, self()})
                     Process.sleep(4_000)
                   end
                 }
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert out =~ "hello"
      assert out =~ "exit code: 0"
      assert elapsed < 1_000

      assert_receive {:slow_worker_pid, slow_worker}, 500
      ref = Process.monitor(slow_worker)
      assert_receive {:DOWN, ^ref, :process, ^slow_worker, _}, 500

      # 2. High-volume output (~1 MiB) with a slow callback stays bounded under backpressure
      #    and finishes cleanly without exhausting memory.
      chunks_seen = :atomics.new(1, signed: false)
      bytes_seen = :atomics.new(1, signed: false)

      assert {:ok, big_out} =
               Bash.execute(
                 %{
                   "command" => "head -c 1048576 /dev/zero | tr '\\0' A",
                   "timeout" => 5_000
                 },
                 %{
                   bash_restricted: false,
                   bash_on_output: fn chunk ->
                     :atomics.add(chunks_seen, 1, 1)
                     :atomics.add(bytes_seen, 1, byte_size(chunk))
                     Process.sleep(40)
                   end
                 }
               )

      assert big_out =~ "exit code: 0"
      assert big_out =~ "bytes of output truncated"
      assert :atomics.get(chunks_seen, 1) >= 1
      assert :atomics.get(bytes_seen, 1) < 1_048_576

      # 3. Direct Bash.execute with a raising :on_tool_update still tears down the
      #    :bash_on_output worker (no orphaned worker left in output_worker_loop).
      assert {:error, crash_msg} =
               Bash.execute(
                 %{
                   "command" => "echo first; sleep 0.1; echo second; sleep 5",
                   "timeout" => 5_000
                 },
                 %{
                   bash_restricted: false,
                   bash_on_output: fn _chunk ->
                     send(parent, {:crash_worker_pid, self()})
                     :ok
                   end,
                   on_tool_update: fn chunk ->
                     if String.contains?(chunk, "second"), do: raise("direct_update_boom")
                     :ok
                   end
                 }
               )

      assert crash_msg =~ "Executor crashed"
      assert_receive {:crash_worker_pid, wpid}, 500
      wref = Process.monitor(wpid)
      assert_receive {:DOWN, ^wref, :process, ^wpid, _}, 500

      # 4. Brutally killing run_port while :bash_on_output is blocked must still kill the
      #    callback worker immediately via its owner-monitoring watcher.
      blocker =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      bash_task =
        Task.async(fn ->
          Bash.execute(
            %{"command" => "echo live; sleep 10", "timeout" => 5_000},
            %{
              bash_restricted: false,
              on_tool_update: fn _chunk ->
                send(parent, {:brutal_runner_pid, self()})
                :ok
              end,
              bash_on_output: fn _chunk ->
                send(parent, {:brutal_worker_pid, self()})
                bref = Process.monitor(blocker)

                receive do
                  {:DOWN, ^bref, :process, ^blocker, _} -> :ok
                end
              end
            }
          )
        end)

      assert_receive {:brutal_runner_pid, runner_pid}, 1_000
      assert_receive {:brutal_worker_pid, blocked_worker_pid}, 1_000
      blocked_ref = Process.monitor(blocked_worker_pid)
      Process.exit(runner_pid, :kill)

      assert {:error, kill_msg} = Task.await(bash_task, 2_000)
      assert kill_msg =~ "Executor crashed"
      assert_receive {:DOWN, ^blocked_ref, :process, ^blocked_worker_pid, :killed}, 500
      send(blocker, :stop)
    end

    test "State.prepare(reasoning: ...) preserves provider_state and provider_response_metadata" do
      state =
        State.init(Config.from_opts(provider: {Anthropic, api_key: "sk-ant", reasoning: :high}))

      state = %{
        state
        | provider_state: %{container_id: "cntr_123"},
          provider_response_metadata: %{model_version: "claude-sonnet-4-6"}
      }

      updated = State.prepare(state, reasoning: :off)
      assert updated.config.reasoning == %{effort: :off, display: nil}
      assert updated.provider_state == %{container_id: "cntr_123"}
      assert updated.provider_response_metadata == %{model_version: "claude-sonnet-4-6"}
    end

    test "provider header correlation, retry suppression, and burst timeout priority" do
      parent = self()

      # 1. OpenAI: rejected header (empty name, valid item.id) + subsequent argument delta
      #    must NOT bypass suppression and must still retry on response.failed.
      rej_attempts = :atomics.new(1, signed: false)

      rej_oai_plug = fn conn ->
        n = :atomics.add_get(rej_attempts, 1, 1)

        sse =
          if n == 1 do
            sse_oai("response.output_item.added", %{
              "type" => "response.output_item.added",
              "output_index" => 0,
              "item" => %{
                "id" => "fc_bad",
                "call_id" => "call_bad",
                "type" => "function_call",
                "name" => ""
              }
            }) <>
              sse_oai("response.function_call_arguments.delta", %{
                "type" => "response.function_call_arguments.delta",
                "output_index" => 0,
                "item_id" => "fc_bad",
                "delta" => "{\"text\":\"hi\"}"
              }) <>
              sse_oai("response.failed", %{
                "type" => "response.failed",
                "response" => %{
                  "status" => "failed",
                  "error" => %{"code" => "server_error", "message" => "transient"}
                }
              })
          else
            sse_oai("response.completed", %{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp_ok3",
                "status" => "completed",
                "output" => [
                  %{
                    "type" => "message",
                    "role" => "assistant",
                    "content" => [%{"type" => "output_text", "text" => "retried ok"}]
                  }
                ],
                "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
              }
            })
          end

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end

      assert {:ok, %{text: "retried ok"}} =
               Alloy.stream("hi", fn _ -> :ok end,
                 provider:
                   {OpenAI,
                    api_key: "sk-oai", model: "gpt-5.4", req_options: [plug: rej_oai_plug]},
                 max_retries: 1,
                 retry_backoff_ms: 0,
                 on_event: &send(parent, {:rej_ev, &1})
               )

      assert :atomics.get(rej_attempts, 1) == 2
      refute Enum.any?(drain_tagged(:rej_ev), &(&1.event == :tool_call_delta))

      # 2. OpenAI: headerless function_call_arguments.delta with item_id "fc_1" followed by
      #    response.completed with call_id "call_1" must correlate using "call_1" (never "fc_1").
      headerless_plug =
        sse_plug(
          sse_oai("response.function_call_arguments.delta", %{
            "type" => "response.function_call_arguments.delta",
            "output_index" => 0,
            "item_id" => "fc_1",
            "delta" => "{\"text\":\"hello\"}"
          }) <>
            sse_oai("response.completed", %{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp_hl",
                "status" => "completed",
                "output" => [
                  %{
                    "type" => "function_call",
                    "id" => "fc_1",
                    "call_id" => "call_1",
                    "name" => "echo",
                    "arguments" => "{\"text\":\"hello\"}"
                  }
                ],
                "usage" => %{"input_tokens" => 2, "output_tokens" => 2}
              }
            })
        )

      {:ok, %{messages: [assistant_msg]}} =
        OpenAI.stream(
          [Message.user("hi")],
          [],
          %{
            api_key: "sk-oai",
            model: "gpt-5.4",
            req_options: [plug: headerless_plug],
            on_event: &send(parent, {:hl_ev, &1})
          },
          fn _ -> :ok end
        )

      assert [%{type: "tool_use", id: "call_1", name: "echo", input: %{"text" => "hello"}}] =
               assistant_msg.content

      hl_deltas =
        drain_tagged(:hl_ev)
        |> Enum.filter(&match?({:tool_call_delta, _}, &1))
        |> Enum.map(fn {:tool_call_delta, p} -> p end)

      assert Enum.all?(hl_deltas, &(&1.id == "call_1" and &1.name == "echo"))
      assert Enum.any?(hl_deltas, &(&1.arguments_delta == "{\"text\":\"hello\"}"))

      # 3. Anthropic: empty tool_use id suppresses :tool_call_delta and still retries on overloaded_error.
      ant_attempts = :atomics.new(1, signed: false)

      ant_empty_id_plug = fn conn ->
        n = :atomics.add_get(ant_attempts, 1, 1)

        sse =
          if n == 1 do
            sse_ant("message_start", %{
              "type" => "message_start",
              "message" => %{
                "id" => "m1",
                "role" => "assistant",
                "usage" => %{"input_tokens" => 1}
              }
            }) <>
              sse_ant("content_block_start", %{
                "type" => "content_block_start",
                "index" => 0,
                "content_block" => %{
                  "type" => "tool_use",
                  "id" => "",
                  "name" => "echo",
                  "input" => %{}
                }
              }) <>
              sse_ant("content_block_delta", %{
                "type" => "content_block_delta",
                "index" => 0,
                "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"text\":\"x\"}"}
              }) <>
              sse_ant("error", %{
                "type" => "error",
                "error" => %{"type" => "overloaded_error", "message" => "busy"}
              })
          else
            sse_ant("message_start", %{
              "type" => "message_start",
              "message" => %{
                "id" => "m2",
                "role" => "assistant",
                "usage" => %{"input_tokens" => 1}
              }
            }) <>
              sse_ant("content_block_start", %{
                "type" => "content_block_start",
                "index" => 0,
                "content_block" => %{"type" => "text", "text" => ""}
              }) <>
              sse_ant("content_block_delta", %{
                "type" => "content_block_delta",
                "index" => 0,
                "delta" => %{"type" => "text_delta", "text" => "recovered"}
              }) <>
              sse_ant("content_block_stop", %{"type" => "content_block_stop", "index" => 0}) <>
              sse_ant("message_delta", %{
                "type" => "message_delta",
                "delta" => %{"stop_reason" => "end_turn"},
                "usage" => %{"output_tokens" => 1}
              }) <>
              sse_ant("message_stop", %{"type" => "message_stop"})
          end

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse)
      end

      assert {:ok, %{text: "recovered"}} =
               Alloy.stream("hi", fn _ -> :ok end,
                 provider:
                   {Anthropic,
                    api_key: "sk-ant",
                    model: "claude-sonnet-4-6",
                    req_options: [plug: ant_empty_id_plug]},
                 max_retries: 1,
                 retry_backoff_ms: 0,
                 on_event: &send(parent, {:ant_bad_ev, &1})
               )

      assert :atomics.get(ant_attempts, 1) == 2
      refute Enum.any?(drain_tagged(:ant_bad_ev), &(&1.event == :tool_call_delta))

      # 4. Gemini extra_body["generationConfig"]["thinking_config"] prevents duplicate thinkingConfig.
      gem_capture = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(parent, {:gem_body, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "candidates" => [
              %{"content" => %{"parts" => [%{"text" => "ok"}]}, "finishReason" => "STOP"}
            ],
            "usageMetadata" => %{"promptTokenCount" => 1, "candidatesTokenCount" => 1}
          })
        )
      end

      assert {:ok, _} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 %{
                   api_key: "sk-gem",
                   model: "gemini-2.5-flash",
                   reasoning: :high,
                   extra_body: %{
                     "generationConfig" => %{"thinking_config" => %{"thinkingBudget" => 512}}
                   },
                   req_options: [plug: gem_capture]
                 }
               )

      assert_received {:gem_body, %{"generationConfig" => gem_gen_cfg}}
      refute Map.has_key?(gem_gen_cfg, "thinkingConfig")
      assert gem_gen_cfg["thinking_config"] == %{"thinkingBudget" => 512}

      # 5. Executor prioritizes terminal timeout over a burst of 150 queued updates with slow :on_event.
      burst_tool = %Inline{
        name: "burst",
        description: "Emits 150 updates then hangs",
        input_schema: %{type: "object", properties: %{}},
        execute: fn _input, context ->
          fun = Map.fetch!(context, :on_tool_update)
          Enum.each(1..150, fn i -> fun.("u-#{i}") end)
          Process.sleep(5_000)
          {:ok, "never"}
        end
      }

      {:ok, burst_pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([%{id: "c_burst", name: "burst", input: %{}}]),
          TestProvider.text_response("done")
        ])

      burst_started = System.monotonic_time(:millisecond)

      assert {:ok, _} =
               Alloy.run("go",
                 provider: {TestProvider, agent_pid: burst_pid},
                 tools: [burst_tool],
                 tool_timeout: 40,
                 timeout_ms: 500,
                 on_event: fn
                   %{event: :tool_update} = ev ->
                     send(parent, {:burst_ev, ev})
                     Process.sleep(10)

                   ev ->
                     send(parent, {:burst_ev, ev})
                 end
               )

      burst_elapsed = System.monotonic_time(:millisecond) - burst_started
      assert burst_elapsed < 350
      burst_updates = Enum.filter(drain_tagged(:burst_ev), &(&1.event == :tool_update))
      assert length(burst_updates) < 50

      # 6. Unsubscribed Alloy.stream/3 still fires [:alloy, :event] :text_delta telemetry.
      tel_handler = "slice2-text-delta-#{inspect(make_ref())}"

      :telemetry.attach(
        tel_handler,
        [:alloy, :event],
        fn _ev, _m, meta, _ ->
          if meta.event == :text_delta, do: send(parent, {:tel_text_delta, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(tel_handler) end)

      ok_oai_plug =
        sse_plug(
          sse_oai("response.output_text.delta", %{
            "type" => "response.output_text.delta",
            "delta" => "hello"
          }) <>
            sse_oai("response.completed", %{
              "type" => "response.completed",
              "response" => %{
                "id" => "resp_tel",
                "status" => "completed",
                "output" => [
                  %{
                    "type" => "message",
                    "role" => "assistant",
                    "content" => [%{"type" => "output_text", "text" => "hello"}]
                  }
                ],
                "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
              }
            })
        )

      assert {:ok, %{text: "hello"}} =
               Alloy.stream("hi", fn _ -> :ok end,
                 provider:
                   {OpenAI, api_key: "sk-oai", model: "gpt-5.4", req_options: [plug: ok_oai_plug]}
               )

      assert_received {:tel_text_delta, %{event: :text_delta, turn: 1}}
    end
  end

  defp wait_until_dead(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_dead(os_pid, deadline)
  end

  defp do_wait_until_dead(os_pid, deadline) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(25)
          do_wait_until_dead(os_pid, deadline)
        end

      _ ->
        true
    end
  end

  defp drain_tagged(tag, acc \\ []) do
    receive do
      {^tag, val} -> drain_tagged(tag, [val | acc])
    after
      0 -> Enum.reverse(acc)
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
