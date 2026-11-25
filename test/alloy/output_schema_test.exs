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
    required: ["answer"],
    additionalProperties: false
  }

  describe "normalize!/1" do
    test "returns nil for nil and normalizes plain JSON Schema maps" do
      assert OutputSchema.normalize!(nil) == nil

      spec = OutputSchema.normalize!(@answer_schema)
      assert spec.name == "alloy_output"
      assert spec.strict == true
      assert spec.schema["type"] == "object"
      assert spec.schema["required"] == ["answer"]
    end

    test "normalizes wrapper maps with custom name and strict flag" do
      spec = OutputSchema.normalize!(%{name: "answer_v1", strict: false, schema: @answer_schema})
      assert spec.name == "answer_v1"
      assert spec.strict == false
      assert spec.schema["type"] == "object"
    end

    test "rejects invalid shapes, names, strict values, structs, and duplicate keys" do
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
    end

    @tag :ex_json_schema
    test "rejects remote $ref at startup and allows Draft 2020-12 passthrough" do
      assert_raise ArgumentError, ~r/local/i, fn ->
        OutputSchema.normalize!(%{
          type: "object",
          properties: %{x: %{"$ref" => "https://example.com/schema.json"}}
        })
      end

      draft_2020 = %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "required" => ["answer"],
        "properties" => %{"answer" => %{"type" => "string"}}
      }

      spec = OutputSchema.normalize!(draft_2020)

      assert {:ok, %{"answer" => "ok"}} =
               OutputSchema.decode_and_validate(~s({"answer":"ok"}), spec)

      assert {:error, msg} = OutputSchema.decode_and_validate(~s({}), spec)
      assert msg =~ "missing required keys: answer"
    end
  end

  describe "provider wire-format translation" do
    test "Anthropic emits output_config.format and lets extra_body override" do
      test_pid = self()

      Req.Test.stub(:output_schema_anthropic, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:anthropic_body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "id" => "msg_1",
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => ~s({"answer":"42"})}],
          "stop_reason" => "end_turn",
          "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
        })
      end)

      assert {:ok,
              %Result{status: :completed, text: ~s({"answer":"42"}), output: %{"answer" => "42"}}} =
               Alloy.run("answer",
                 provider:
                   {Anthropic,
                    api_key: "k",
                    model: "claude-sonnet-5-5",
                    req_options: [plug: {Req.Test, :output_schema_anthropic}]},
                 output_schema: @answer_schema
               )

      assert_received {:anthropic_body, body}

      assert %{
               "format" => %{
                 "type" => "json_schema",
                 "schema" => %{"type" => "object", "required" => ["answer"]}
               }
             } = body["output_config"]
    end

    test "OpenAI and XAI emit text.format json_schema" do
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
                "content" => [%{"type" => "output_text", "text" => ~s({"answer":"ok"})}]
              }
            ],
            "usage" => %{"input_tokens" => 5, "output_tokens" => 4}
          })
        end)

        assert {:ok, %Result{output: %{"answer" => "ok"}}} =
                 Alloy.run("answer",
                   provider:
                     {mod, api_key: "k", model: "gpt-5.4", req_options: [plug: {Req.Test, label}]},
                   output_schema: %{name: "ans", schema: @answer_schema, strict: true}
                 )

        assert_received {^label, body}

        assert %{
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
              "message" => %{"role" => "assistant", "content" => ~s({"answer":"hi"})}
            }
          ],
          "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2}
        })
      end)

      assert {:ok, %Result{output: %{"answer" => "hi"}}} =
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

    test "Gemini emits generationConfig responseMimeType and responseJsonSchema" do
      test_pid = self()

      Req.Test.stub(:output_schema_gemini, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:gemini_body, Jason.decode!(raw)})

        Req.Test.json(conn, %{
          "candidates" => [
            %{
              "content" => %{"parts" => [%{"text" => ~s({"answer":"gem"})}]},
              "finishReason" => "STOP"
            }
          ],
          "usageMetadata" => %{"promptTokenCount" => 3, "candidatesTokenCount" => 2}
        })
      end)

      assert {:ok, %Result{output: %{"answer" => "gem"}}} =
               Alloy.run("answer",
                 provider:
                   {Gemini,
                    api_key: "k",
                    model: "gemini-3-flash",
                    req_options: [plug: {Req.Test, :output_schema_gemini}]},
                 output_schema: @answer_schema
               )

      assert_received {:gemini_body, body}
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
            text: ~s({"answer":"codex"}),
            tool_calls: []
          })

        File.write!(out_path, reply)
        {"", 0}
      end

      assert {:ok, %Result{output: %{"answer" => "codex"}}} =
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
    test "returns error when final text is invalid JSON or fails schema validation" do
      {:ok, pid} =
        Alloy.Provider.Test.start_link([
          Alloy.Testing.text_response("not json at all")
        ])

      assert {:error, %Result{status: :error, output: nil, error: msg}} =
               Alloy.run("hi",
                 provider: {Alloy.Provider.Test, agent_pid: pid},
                 output_schema: @answer_schema
               )

      assert msg =~ "Structured output is not valid JSON"
    end

    @tag :ex_json_schema
    test "returns schema validation error when JSON violates schema constraints" do
      {:ok, pid} =
        Alloy.Provider.Test.start_link([
          Alloy.Testing.text_response(~s({"answer":123}))
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
          Alloy.Testing.text_response(~s({"answer":"clean"}))
        ])

      assert {:ok, %Result{output: %{"answer" => "clean"}, metadata: meta}} =
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
             output_schema: @answer_schema,
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
