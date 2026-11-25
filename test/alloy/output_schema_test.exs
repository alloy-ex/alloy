defmodule Alloy.OutputSchemaTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Context.Compactor
  alias Alloy.{Message, OutputSchema, Result}
  alias Alloy.Provider.{Anthropic, Codex, CodexSession, Error, Gemini, OpenAI, OpenAICompat, XAI}

  @answer_schema %{
    type: "object",
    properties: %{
      answer: %{type: "string"},
      confidence: %{type: "number"}
    },
    required: ["answer", "confidence"],
    additionalProperties: false
  }

  describe "normalize!/1 and wire/1" do
    test "returns nil for nil and normalizes plain JSON Schema maps" do
      assert OutputSchema.normalize!(nil) == nil

      spec = OutputSchema.normalize!(@answer_schema)
      assert %OutputSchema{name: "alloy_output", strict: true} = spec
      assert spec.schema["type"] == "object"
      assert spec.schema["required"] == ["answer", "confidence"]
      assert OutputSchema.wire(spec) == spec
    end

    test "normalizes wrapper maps with custom name and strict flag" do
      spec = OutputSchema.normalize!(%{name: "answer_v1", strict: false, schema: @answer_schema})
      assert spec.name == "answer_v1"
      assert spec.strict == false
      assert spec.schema["type"] == "object"
    end

    test "rejects invalid shapes, names, strict values, structs, duplicate keys, and provider-level output_schema" do
      assert_raise ArgumentError, ~r/non-empty JSON Schema map/, fn ->
        OutputSchema.normalize!(%{})
      end

      assert_raise ArgumentError, ~r/struct/, fn ->
        OutputSchema.normalize!(Message.user("hi"))
      end

      assert_raise ArgumentError, ~r/:name must match/, fn ->
        OutputSchema.normalize!(%{name: "bad name!", schema: @answer_schema})
      end

      assert_raise ArgumentError, ~r/:strict must be a boolean/, fn ->
        OutputSchema.normalize!(%{strict: "yes", schema: @answer_schema})
      end

      assert_raise ArgumentError, ~r/both :name and "name"/, fn ->
        OutputSchema.normalize!(%{:name => "a", "name" => "b", :schema => @answer_schema})
      end

      assert_raise ArgumentError, ~r/Invalid output_schema/, fn ->
        OutputSchema.normalize!(%{:type => "object", "type" => "array"})
      end

      assert_raise ArgumentError, ~r/:schema must be a non-empty/, fn ->
        OutputSchema.normalize!(%{schema: %{}})
      end

      assert_raise ArgumentError, ~r/:name must be a string/, fn ->
        OutputSchema.normalize!(%{name: 123, schema: @answer_schema})
      end

      assert_raise ArgumentError, ~r/top-level Alloy\.run\/2 option/, fn ->
        Config.from_opts(
          provider:
            {Anthropic, api_key: "k", model: "claude-sonnet-5-5", output_schema: @answer_schema}
        )
      end

      assert_raise ArgumentError, ~r/:name must match/, fn ->
        OutputSchema.normalize!(%OutputSchema{
          name: "bad name!",
          schema: @answer_schema,
          strict: true
        })
      end

      assert_raise ArgumentError, ~r/unsupported key/, fn ->
        OutputSchema.normalize!(%{
          name: "ans",
          schema: @answer_schema,
          strict: true,
          description: "belongs inside schema"
        })
      end
    end

    test "basic fallback validation covers JSON types, Draft 6+ whole floats, union types, and missing text" do
      draft_2020 = fn extra ->
        Map.merge(%{"$schema" => "https://json-schema.org/draft/2020-12/schema"}, extra)
        |> OutputSchema.normalize!()
      end

      assert {:ok, [1, 2]} =
               OutputSchema.decode_and_validate("[1,2]", draft_2020.(%{"type" => "array"}))

      assert {:ok, "hi"} =
               OutputSchema.decode_and_validate(~s("hi"), draft_2020.(%{"type" => "string"}))

      assert {:ok, 7} =
               OutputSchema.decode_and_validate("7", draft_2020.(%{"type" => "integer"}))

      assert {:ok, 1.0} =
               OutputSchema.decode_and_validate("1.0", draft_2020.(%{"type" => "integer"}))

      assert {:error, _} =
               OutputSchema.decode_and_validate("1.5", draft_2020.(%{"type" => "integer"}))

      assert {:ok, 1.5} =
               OutputSchema.decode_and_validate("1.5", draft_2020.(%{"type" => "number"}))

      assert {:ok, true} =
               OutputSchema.decode_and_validate("true", draft_2020.(%{"type" => "boolean"}))

      assert {:ok, nil} =
               OutputSchema.decode_and_validate("null", draft_2020.(%{"type" => "null"}))

      assert {:ok, "ok"} =
               OutputSchema.decode_and_validate(
                 ~s("ok"),
                 draft_2020.(%{"type" => ["string", "null"]})
               )

      assert {:error, msg} =
               OutputSchema.decode_and_validate(
                 "123",
                 draft_2020.(%{"type" => ["string", "null"]})
               )

      assert msg =~ "did not match any expected JSON type"

      assert {:error, type_msg} =
               OutputSchema.decode_and_validate("123", draft_2020.(%{"type" => "string"}))

      assert type_msg =~ "expected JSON type"

      assert {:error, missing_msg} =
               OutputSchema.decode_and_validate(nil, OutputSchema.normalize!(@answer_schema))

      assert missing_msg =~ "missing assistant text"
    end

    @tag :ex_json_schema
    test "rejects remote $ref with output_schema wording and bounds large validation error lists" do
      err =
        assert_raise ArgumentError, fn ->
          OutputSchema.normalize!(%{
            type: "object",
            properties: %{x: %{"$ref" => "https://example.com/schema.json"}}
          })
        end

      assert Exception.message(err) =~ "output_schema"
      refute Exception.message(err) =~ "tool schema"

      array_spec =
        OutputSchema.normalize!(%{
          type: "array",
          items: %{type: "integer"}
        })

      bad_items = Jason.encode!(List.duplicate("not-an-int", 25))
      assert {:error, msg} = OutputSchema.decode_and_validate(bad_items, array_spec)
      assert msg =~ "(+15 more)"
      assert byte_size(msg) <= 1_100
    end
  end

  describe "provider wire-format translation" do
    test "Anthropic emits output_config.format and preserves sibling extra_body effort" do
      test_pid = self()

      Req.Test.stub(:output_schema_anthropic, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:anthropic_body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => ~s({"answer":"42","confidence":0.9})}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
        })
      end)

      assert {:ok,
              %Result{
                status: :completed,
                text: ~s({"answer":"42","confidence":0.9}),
                output: %{"answer" => "42", "confidence" => 0.9}
              }} =
               Alloy.run("answer",
                 provider:
                   {Anthropic,
                    api_key: "k",
                    model: "claude-sonnet-5-5",
                    extra_body: %{"output_config" => %{"effort" => "high"}},
                    req_options: [plug: {Req.Test, :output_schema_anthropic}]},
                 output_schema: @answer_schema
               )

      assert_received {:anthropic_body, body}

      assert %{
               "effort" => "high",
               "format" => %{
                 "type" => "json_schema",
                 "schema" => %{"type" => "object", "required" => ["answer", "confidence"]}
               }
             } = body["output_config"]

      # Explicit caller format inside extra_body.output_config still wins.
      assert {:ok, _} =
               Alloy.run("answer",
                 provider:
                   {Anthropic,
                    api_key: "k",
                    model: "claude-sonnet-5-5",
                    extra_body: %{
                      "output_config" => %{
                        "effort" => "low",
                        "format" => %{"type" => "json_schema", "schema" => %{"type" => "object"}}
                      }
                    },
                    req_options: [plug: {Req.Test, :output_schema_anthropic}]},
                 output_schema: @answer_schema
               )

      assert_received {:anthropic_body, override_body}
      assert override_body["output_config"]["effort"] == "low"
      assert override_body["output_config"]["format"]["schema"] == %{"type" => "object"}
    end

    test "OpenAI and XAI emit text.format json_schema and preserve sibling extra_body text keys" do
      test_pid = self()

      for {label, mod} <- [{:output_schema_openai, OpenAI}, {:output_schema_xai, XAI}] do
        Req.Test.stub(label, fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {label, Jason.decode!(raw)})

          Req.Test.json(conn, %{
            "id" => "resp_1",
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => [
                  %{"type" => "output_text", "text" => ~s({"answer":"ok","confidence":1})}
                ]
              }
            ],
            "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
          })
        end)

        assert {:ok, %Result{output: %{"answer" => "ok", "confidence" => 1}}} =
                 Alloy.run("answer",
                   provider:
                     {mod,
                      api_key: "k",
                      model: "gpt-5.4",
                      extra_body: %{"text" => %{"verbosity" => "low"}},
                      req_options: [plug: {Req.Test, label}]},
                   output_schema: %{name: "ans", schema: @answer_schema, strict: true}
                 )

        assert_received {^label, body}

        assert %{
                 "verbosity" => "low",
                 "format" => %{
                   "type" => "json_schema",
                   "name" => "ans",
                   "strict" => true,
                   "schema" => %{"type" => "object"}
                 }
               } = body["text"]
      end
    end

    test "OpenAICompat emits response_format json_schema" do
      test_pid = self()

      Req.Test.stub(:output_schema_compat, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:compat_body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "choices" => [
            %{
              "finish_reason" => "stop",
              "message" => %{
                "role" => "assistant",
                "content" => ~s({"answer":"hi","confidence":0.5})
              }
            }
          ],
          "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2}
        })
      end)

      assert {:ok, %Result{output: %{"answer" => "hi", "confidence" => 0.5}}} =
               Alloy.run("answer",
                 provider:
                   {OpenAICompat,
                    api_url: "http://localhost",
                    model: "m",
                    req_options: [plug: {Req.Test, :output_schema_compat}]},
                 output_schema: @answer_schema
               )

      assert_received {:compat_body, body}

      assert %{
               "type" => "json_schema",
               "json_schema" => %{
                 "name" => "alloy_output",
                 "strict" => true,
                 "schema" => %{"type" => "object"}
               }
             } = body["response_format"]
    end

    test "Gemini emits generationConfig responseMimeType/responseJsonSchema and preserves extra_body generationConfig" do
      test_pid = self()

      Req.Test.stub(:output_schema_gemini, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:gemini_body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [%{"text" => ~s({"answer":"gem","confidence":0.8})}]
              },
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{"promptTokenCount" => 3, "candidatesTokenCount" => 2}
        })
      end)

      assert {:ok, %Result{output: %{"answer" => "gem", "confidence" => 0.8}}} =
               Alloy.run("answer",
                 provider:
                   {Gemini,
                    api_key: "k",
                    model: "gemini-3-flash",
                    extra_body: %{"generationConfig" => %{"temperature" => 0.2}},
                    req_options: [plug: {Req.Test, :output_schema_gemini}]},
                 output_schema: @answer_schema
               )

      assert_received {:gemini_body, body}
      assert body["generationConfig"]["temperature"] == 0.2
      assert body["generationConfig"]["responseMimeType"] == "application/json"
      assert body["generationConfig"]["responseJsonSchema"]["type"] == "object"

      assert {:error, %Error{kind: :invalid_request, message: msg1}} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 %{
                   api_key: "k",
                   model: "gemini-3-flash",
                   generation_config: %{responseSchema: %{type: "OBJECT"}},
                   output_schema: @answer_schema
                 }
               )

      assert msg1 =~ ~s(legacy generationConfig["responseSchema"])

      assert {:error, %Error{kind: :invalid_request, message: msg2}} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 %{
                   api_key: "k",
                   model: "gemini-3-flash",
                   generation_config: %{responseMimeType: "text/plain"},
                   output_schema: @answer_schema
                 }
               )

      assert msg2 =~ ~s(non-JSON generationConfig["responseMimeType"])

      assert {:error, %Error{kind: :invalid_request, message: msg3}} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 %{
                   api_key: "k",
                   model: "gemini-3-flash",
                   extra_body: %{
                     "generationConfig" => %{"responseSchema" => %{"type" => "OBJECT"}}
                   },
                   output_schema: @answer_schema
                 }
               )

      assert msg3 =~ ~s(legacy generationConfig["responseSchema"])

      assert {:error, %Error{kind: :invalid_request, message: msg4}} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 %{
                   api_key: "k",
                   model: "gemini-3-flash",
                   extra_body: %{generationConfig: %{responseMimeType: "text/plain"}},
                   output_schema: @answer_schema
                 }
               )

      assert msg4 =~ ~s(non-JSON generationConfig["responseMimeType"])

      assert {:error, %Error{kind: :invalid_request, message: msg5}} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 %{
                   api_key: "k",
                   model: "gemini-3-flash",
                   generation_config: %{response_schema: %{type: "OBJECT"}},
                   output_schema: @answer_schema
                 }
               )

      assert msg5 =~ ~s(legacy generationConfig["responseSchema"])

      assert {:error, %Error{kind: :invalid_request, message: msg6}} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 %{
                   api_key: "k",
                   model: "gemini-3-flash",
                   generation_config: %{response_mime_type: "application/json"},
                   output_schema: @answer_schema
                 }
               )

      assert msg6 =~ "snake_case generationConfig keys"

      assert {:error, %Error{kind: :invalid_request, message: msg7}} =
               Gemini.complete(
                 [Message.user("hi")],
                 [],
                 %{
                   api_key: "k",
                   model: "gemini-3-flash",
                   extra_body: %{generationConfig: %{response_json_schema: %{type: "object"}}},
                   output_schema: @answer_schema
                 }
               )

      assert msg7 =~ "snake_case generationConfig keys"
    end

    test "atom-keyed nested extra_body merges without duplicate JSON keys and lets caller win" do
      test_pid = self()

      Req.Test.stub(:atom_extra_anthropic, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw_anthropic, raw})

        Req.Test.json(conn, %{
          "id" => "msg_atom",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => ~s({"answer":"ok","confidence":1})}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
        })
      end)

      assert {:ok, _} =
               Alloy.run("answer",
                 provider:
                   {Anthropic,
                    api_key: "k",
                    model: "claude-sonnet-5-5",
                    extra_body: %{
                      output_config: %{
                        effort: "low",
                        format: %{type: "json_schema", schema: %{type: "object"}}
                      }
                    },
                    req_options: [plug: {Req.Test, :atom_extra_anthropic}]},
                 output_schema: @answer_schema
               )

      assert_received {:raw_anthropic, raw_anthropic}
      assert length(Regex.scan(~r/"format":/, raw_anthropic)) == 1
      assert Jason.decode!(raw_anthropic)["output_config"]["effort"] == "low"

      assert Jason.decode!(raw_anthropic)["output_config"]["format"]["schema"] == %{
               "type" => "object"
             }

      Req.Test.stub(:atom_extra_openai, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw_openai, raw})

        Req.Test.json(conn, %{
          "id" => "resp_atom",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "output_text", "text" => ~s({"answer":"ok","confidence":1})}
              ]
            }
          ],
          "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
        })
      end)

      assert {:ok, _} =
               Alloy.run("answer",
                 provider:
                   {OpenAI,
                    api_key: "k",
                    model: "gpt-5.4",
                    extra_body: %{
                      text: %{
                        verbosity: "low",
                        format: %{
                          type: "json_schema",
                          name: "caller_override",
                          schema: %{type: "object"},
                          strict: false
                        }
                      }
                    },
                    req_options: [plug: {Req.Test, :atom_extra_openai}]},
                 output_schema: @answer_schema
               )

      assert_received {:raw_openai, raw_openai}
      assert length(Regex.scan(~r/"format":/, raw_openai)) == 1
      assert Jason.decode!(raw_openai)["text"]["verbosity"] == "low"
      assert Jason.decode!(raw_openai)["text"]["format"]["name"] == "caller_override"

      Req.Test.stub(:atom_extra_gemini, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:raw_gemini, raw})

        Req.Test.json(conn, %{
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => "plain text"}]},
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{"promptTokenCount" => 3, "candidatesTokenCount" => 2}
        })
      end)

      assert {:ok, _} =
               Alloy.run("answer",
                 provider:
                   {Gemini,
                    api_key: "k",
                    model: "gemini-3-flash",
                    max_tokens: 1024,
                    extra_body: %{generationConfig: %{maxOutputTokens: 512}},
                    req_options: [plug: {Req.Test, :atom_extra_gemini}]}
               )

      assert_received {:raw_gemini, raw_gemini}
      assert length(Regex.scan(~r/"maxOutputTokens":/, raw_gemini)) == 1
      assert Jason.decode!(raw_gemini)["generationConfig"]["maxOutputTokens"] == 512
    end

    test "Codex embeds output_schema rules into its prompt" do
      test_pid = self()

      runner = fn _bin, args, _opts ->
        out_idx = Enum.find_index(args, &(&1 == "--output-last-message"))
        out_path = Enum.at(args, out_idx + 1)
        prompt = List.last(args)
        send(test_pid, {:codex_prompt, prompt})

        reply =
          Jason.encode!(%{
            stop_reason: "end_turn",
            text: ~s({"answer":"codex","confidence":1}),
            tool_calls: []
          })

        File.write!(out_path, reply)
        {"", 0}
      end

      assert {:ok, %Result{output: %{"answer" => "codex", "confidence" => 1}}} =
               Alloy.run("answer",
                 provider: {Codex, model: "gpt-5.4", command_runner: runner},
                 output_schema: @answer_schema
               )

      assert_received {:codex_prompt, prompt}
      assert prompt =~ "conforming strictly to this JSON Schema"
      assert prompt =~ ~s("answer")
    end
  end

  describe "loop, middleware, and compactor integration" do
    test "returns error when final text is invalid JSON or truncated at :max_tokens" do
      {:ok, pid} =
        Alloy.Provider.Test.start_link([
          Alloy.Testing.text_response("not json at all")
        ])

      assert {:error, %Result{status: :error, output: nil, text: "not json at all", error: msg}} =
               Alloy.run("hi",
                 provider: {Alloy.Provider.Test, agent_pid: pid},
                 output_schema: @answer_schema
               )

      assert msg =~ "Structured output is not valid JSON"

      {:ok, trunc_pid} =
        Alloy.Provider.Test.start_link([
          {:ok,
           %{
             stop_reason: :max_tokens,
             messages: [Message.assistant(~s({"answer":"cut off))],
             usage: %{input_tokens: 5, output_tokens: 5}
           }}
        ])

      assert {:error,
              %Result{status: :error, output: nil, stop_reason: :max_tokens, error: trunc_msg}} =
               Alloy.run("hi",
                 provider: {Alloy.Provider.Test, agent_pid: trunc_pid},
                 output_schema: @answer_schema
               )

      assert trunc_msg =~ "truncated at :max_tokens"
    end

    @tag :ex_json_schema
    test "returns schema validation error when JSON violates schema constraints" do
      {:ok, pid} =
        Alloy.Provider.Test.start_link([
          Alloy.Testing.text_response(~s({"answer":123,"confidence":0.5}))
        ])

      assert {:error, %Result{status: :error, output: nil, error: msg}} =
               Alloy.run("hi",
                 provider: {Alloy.Provider.Test, agent_pid: pid},
                 output_schema: @answer_schema
               )

      assert msg =~ "Structured output failed schema validation"
    end

    test "before_completion middleware can set or clear output_schema mid-run" do
      test_pid = self()

      defmodule ToggleSchemaMiddleware do
        @behaviour Alloy.Middleware

        def call(:before_completion, state) do
          schema = Map.get(state.config.context, :turn2_schema)

          if state.turn == 1 do
            State.prepare(state, output_schema: schema)
          else
            state
          end
        end

        def call(_hook, state), do: state
      end

      lookup_tool =
        Alloy.Tool.inline(
          name: "lookup",
          description: "Lookup",
          input_schema: %{type: "object", properties: %{}},
          execute: fn _, _ -> {:ok, "42"} end
        )

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(:output_schema_midrun_set, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        turn = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
        send(test_pid, {:midrun_set, turn, Jason.decode!(raw)})

        if turn == 1 do
          Req.Test.json(conn, %{
            "id" => "msg_1",
            "type" => "message",
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_use", "id" => "tu_1", "name" => "lookup", "input" => %{}}
            ],
            "stop_reason" => "tool_use",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
          })
        else
          Req.Test.json(conn, %{
            "id" => "msg_2",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => ~s({"answer":"42","confidence":1})}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
          })
        end
      end)

      assert {:ok, %Result{status: :completed, output: %{"answer" => "42", "confidence" => 1}}} =
               Alloy.run("find and answer",
                 provider:
                   {Anthropic,
                    api_key: "k",
                    model: "claude-sonnet-5-5",
                    req_options: [plug: {Req.Test, :output_schema_midrun_set}]},
                 tools: [lookup_tool],
                 middleware: [ToggleSchemaMiddleware],
                 context: %{turn2_schema: @answer_schema}
               )

      assert_received {:midrun_set, 1, body1}
      assert_received {:midrun_set, 2, body2}
      refute Map.has_key?(body1, "output_config")
      assert body2["output_config"]["format"]["type"] == "json_schema"

      {:ok, clear_counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(:output_schema_midrun_clear, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        turn = Agent.get_and_update(clear_counter, fn n -> {n + 1, n + 1} end)
        send(test_pid, {:midrun_clear, turn, Jason.decode!(raw)})

        if turn == 1 do
          Req.Test.json(conn, %{
            "id" => "msg_c1",
            "type" => "message",
            "role" => "assistant",
            "content" => [
              %{"type" => "tool_use", "id" => "tu_1", "name" => "lookup", "input" => %{}}
            ],
            "stop_reason" => "tool_use",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
          })
        else
          Req.Test.json(conn, %{
            "id" => "msg_c2",
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "plain text after clearing schema"}],
            "stop_reason" => "end_turn",
            "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
          })
        end
      end)

      assert {:ok,
              %Result{
                status: :completed,
                text: "plain text after clearing schema",
                output: nil
              }} =
               Alloy.run("find and answer",
                 provider:
                   {Anthropic,
                    api_key: "k",
                    model: "claude-sonnet-5-5",
                    req_options: [plug: {Req.Test, :output_schema_midrun_clear}]},
                 tools: [lookup_tool],
                 middleware: [ToggleSchemaMiddleware],
                 output_schema: @answer_schema,
                 context: %{turn2_schema: nil}
               )

      assert_received {:midrun_clear, 1, clear_body1}
      assert_received {:midrun_clear, 2, clear_body2}
      assert clear_body1["output_config"]["format"]["type"] == "json_schema"
      refute Map.has_key?(clear_body2, "output_config")
    end

    test "Gemini schema conflict on a fallback provider returns {:error, result} instead of raising" do
      {:ok, primary_pid} =
        Alloy.Provider.Test.start_link([
          {:error, %Error{kind: :overloaded, status: 529, message: "primary overloaded"}}
        ])

      assert {:error, %Result{status: :error, output: nil, error: msg}} =
               Alloy.run("answer",
                 provider: {Alloy.Provider.Test, agent_pid: primary_pid},
                 fallback_providers: [
                   {Gemini,
                    api_key: "k",
                    model: "gemini-3-flash",
                    generation_config: %{responseMimeType: "text/plain"}}
                 ],
                 max_retries: 0,
                 output_schema: @answer_schema
               )

      assert msg =~ ~s(non-JSON generationConfig["responseMimeType"])
    end

    test "custom providers receive %OutputSchema{} when set and omit :output_schema when nil" do
      defmodule CustomSchemaProvider do
        @behaviour Alloy.Provider

        @impl true
        def complete(_messages, _tool_defs, config) do
          send(config.test_pid, {:custom_config, config})

          text =
            if Map.has_key?(config, :output_schema),
              do: ~s({"answer":"custom","confidence":1}),
              else: "plain"

          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [Message.assistant(text)],
             usage: %{input_tokens: 1, output_tokens: 1}
           }}
        end
      end

      assert {:ok, %Result{output: %{"answer" => "custom", "confidence" => 1}}} =
               Alloy.run("hi",
                 provider: {CustomSchemaProvider, test_pid: self()},
                 output_schema: @answer_schema
               )

      assert_received {:custom_config, config_with_schema}
      assert %OutputSchema{name: "alloy_output", strict: true} = config_with_schema.output_schema

      assert {:ok, %Result{text: "plain", output: nil}} =
               Alloy.run("hi", provider: {CustomSchemaProvider, test_pid: self()})

      assert_received {:custom_config, config_without_schema}
      refute Map.has_key?(config_without_schema, :output_schema)
    end

    test "OpenAI refusal under :output_schema reports refusal instead of JSON parse failure" do
      Req.Test.stub(:output_schema_openai_refusal, fn conn ->
        Req.Test.json(conn, %{
          "id" => "resp_refuse",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "refusal", "refusal" => "I cannot comply with that request."}
              ]
            }
          ],
          "usage" => %{"input_tokens" => 5, "output_tokens" => 7}
        })
      end)

      assert {:error,
              %Result{
                status: :error,
                output: nil,
                text: "I cannot comply with that request.",
                error: "The model refused to produce structured output"
              }} =
               Alloy.run("disallowed",
                 provider:
                   {OpenAI,
                    api_key: "k",
                    model: "gpt-5.4",
                    req_options: [plug: {Req.Test, :output_schema_openai_refusal}]},
                 output_schema: @answer_schema
               )
    end

    test "does not duplicate :output inside result.metadata.run and skips validation on stop_after_tool" do
      tool =
        Alloy.Tool.inline(
          name: "finish",
          description: "Done",
          input_schema: %{type: "object", properties: %{}},
          execute: fn _, _ -> {:ok, "plain tool result"} end
        )

      {:ok, pid} =
        Alloy.Provider.Test.start_link([
          Alloy.Testing.tool_response("finish", %{})
        ])

      assert {:ok, %Result{status: :completed, text: "plain tool result", output: nil}} =
               Alloy.run("go",
                 provider: {Alloy.Provider.Test, agent_pid: pid},
                 tools: [tool],
                 stop_after_tool: "finish",
                 output_schema: @answer_schema
               )

      {:ok, pid2} =
        Alloy.Provider.Test.start_link([
          Alloy.Testing.text_response(~s({"answer":"clean","confidence":1}))
        ])

      assert {:ok, %Result{output: %{"answer" => "clean", "confidence" => 1}, metadata: meta}} =
               Alloy.run("go",
                 provider: {Alloy.Provider.Test, agent_pid: pid2},
                 output_schema: @answer_schema
               )

      refute Map.has_key?(Map.get(meta, :run, %{}), :output)
    end

    test "Compactor strips :output_schema from summary requests" do
      test_pid = self()

      Req.Test.stub(:output_schema_compactor, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:summary_body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "id" => "msg_sum",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Compact summary."}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
        })
      end)

      config =
        Config.from_opts(
          provider:
            {Anthropic,
             api_key: "k",
             model: "claude-sonnet-5-5",
             req_options: [plug: {Req.Test, :output_schema_compactor}]},
          output_schema: @answer_schema,
          max_tokens: 1_000,
          compaction: %{reserve_tokens: 200, keep_recent_tokens: 100}
        )

      big_messages =
        [Message.user("start")] ++
          Enum.flat_map(1..6, fn i ->
            [
              Message.user("u#{i} " <> String.duplicate("x", 600)),
              Message.assistant("a#{i} " <> String.duplicate("y", 600))
            ]
          end)

      state = State.init(config, big_messages)
      _compacted = Compactor.force_compact(state)

      assert_received {:summary_body, body}
      refute Map.has_key?(body, "output_config")
    end

    test "forwards :output_schema to fallback_providers and decodes fallback output" do
      test_pid = self()

      Req.Test.stub(:output_schema_primary_down, fn conn ->
        Plug.Conn.send_resp(conn, 503, ~s({"error":{"type":"overloaded_error","message":"busy"}}))
      end)

      Req.Test.stub(:output_schema_fallback_ok, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:fallback_body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "id" => "resp_fb",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [
                %{"type" => "output_text", "text" => ~s({"answer":"fallback","confidence":0.95})}
              ]
            }
          ],
          "usage" => %{"input_tokens" => 4, "output_tokens" => 3}
        })
      end)

      assert {:ok, %Result{output: %{"answer" => "fallback", "confidence" => 0.95}}} =
               Alloy.run("answer",
                 provider:
                   {Anthropic,
                    api_key: "k",
                    model: "claude-sonnet-5-5",
                    req_options: [plug: {Req.Test, :output_schema_primary_down}]},
                 fallback_providers: [
                   {OpenAI,
                    api_key: "k2",
                    model: "gpt-5.4",
                    req_options: [plug: {Req.Test, :output_schema_fallback_ok}]}
                 ],
                 output_schema: @answer_schema,
                 max_retries: 0
               )

      assert_received {:fallback_body, body}
      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["schema"]["type"] == "object"
    end

    test "decodes structured output during streaming and across split assistant text blocks" do
      {:ok, stream_pid} =
        Alloy.Provider.Test.start_link([
          Alloy.Testing.text_response(~s({"answer":"streamed","confidence":0.7}))
        ])

      test_pid = self()

      assert {:ok, %Result{output: %{"answer" => "streamed", "confidence" => 0.7}}} =
               Alloy.stream(
                 "go",
                 fn chunk -> send(test_pid, {:chunk, chunk}) end,
                 provider: {Alloy.Provider.Test, agent_pid: stream_pid},
                 output_schema: @answer_schema
               )

      assert_received {:chunk, _}

      # JSON string split across two text blocks (e.g. Gemini thought-signature chunks)
      # must be concatenated without injecting "\n" inside the string literal.
      {:ok, split_pid} =
        Alloy.Provider.Test.start_link([
          {:ok,
           %{
             stop_reason: :end_turn,
             messages: [
               %Message{
                 role: :assistant,
                 content: [
                   %{type: "text", text: ~s({"answer":"hel)},
                   %{type: "text", text: ~s(lo","confidence":1})}
                 ]
               }
             ],
             usage: %{input_tokens: 2, output_tokens: 2}
           }}
        ])

      assert {:ok, %Result{output: %{"answer" => "hello", "confidence" => 1}}} =
               Alloy.run("go",
                 provider: {Alloy.Provider.Test, agent_pid: split_pid},
                 output_schema: @answer_schema
               )
    end

    test "halting in :after_completion leaves result.output as nil" do
      defmodule HaltAfterCompletion do
        @behaviour Alloy.Middleware
        def call(:after_completion, _state), do: {:halt, "policy rejected"}
        def call(_hook, state), do: state
      end

      {:ok, pid} =
        Alloy.Provider.Test.start_link([
          Alloy.Testing.text_response(~s({"answer":"ok","confidence":1}))
        ])

      assert {:error,
              %Result{
                status: :halted,
                output: nil,
                error: "Halted by middleware: policy rejected"
              }} =
               Alloy.run("go",
                 provider: {Alloy.Provider.Test, agent_pid: pid},
                 middleware: [HaltAfterCompletion],
                 output_schema: @answer_schema
               )
    end

    test "Codex omits :output_schema from session scope when nil so 0.13 persisted sessions resume" do
      workdir = System.tmp_dir!()

      runner = fn _bin, args, _opts ->
        out_idx = Enum.find_index(args, &(&1 == "--output-last-message"))
        out_path = Enum.at(args, out_idx + 1)

        File.write!(
          out_path,
          Jason.encode!(%{stop_reason: "end_turn", text: "ok", tool_calls: []})
        )

        {~s({"type":"thread.started","thread_id":"thread-legacy"}\n), 0}
      end

      legacy_scope = %{
        home: System.get_env("CODEX_HOME") || Path.expand("~/.codex"),
        workdir: workdir,
        model: "gpt-5.4",
        system_prompt: nil,
        overrides: [],
        executable: "codex",
        generation: nil,
        tools: []
      }

      legacy_state =
        CodexSession.remember(
          [%{"role" => "user", "content" => "hi"}, %{"role" => "assistant", "content" => "hey"}],
          legacy_scope,
          "thread-legacy"
        )

      assert {:ok, %{response_metadata: %{session: %{mode: :resumed}}}} =
               Codex.complete(
                 [Message.user("hi"), Message.assistant("hey"), Message.user("next")],
                 [],
                 %{
                   model: "gpt-5.4",
                   persist_session: true,
                   workdir: workdir,
                   provider_state: legacy_state,
                   command_runner: runner
                 }
               )
    end
  end
end
