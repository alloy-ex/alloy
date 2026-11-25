defmodule Alloy.OutputSchemaTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State}
  alias Alloy.Context.Compactor
  alias Alloy.{Message, OutputSchema, Result}
  alias Alloy.Provider.{Anthropic, Codex, Gemini, OpenAI, OpenAICompat, XAI}

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

    test "State.prepare/2 can set or clear output_schema mid-run" do
      config = Config.from_opts(provider: Alloy.Provider.Test)
      state = State.init(config)
      prepared = State.prepare(state, output_schema: @answer_schema)
      assert prepared.config.output_schema.name == "alloy_output"
      cleared = State.prepare(prepared, output_schema: nil)
      assert cleared.config.output_schema == nil
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
  end
end
