defmodule Alloy.Provider.ClaudeCodeTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.ClaudeCode
  alias Alloy.Provider.Error

  describe "complete/3" do
    test "returns an end_turn assistant message from Claude Code JSON output" do
      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            {envelope(%{"stop_reason" => "end_turn", "text" => "All done", "tool_calls" => []}),
             0}
          end)
      }

      assert {:ok, result} = ClaudeCode.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert result.messages == [Message.assistant("All done")]

      assert result.usage == %{
               input_tokens: 5,
               output_tokens: 7,
               cache_creation_input_tokens: 0,
               cache_read_input_tokens: 0
             }

      assert result.response_metadata.backend == "claude_code_print"
      assert result.response_metadata.model == "claude-sonnet-5"
      assert result.response_metadata.session_id == "sess_test"
      assert result.response_metadata.total_cost_usd == 0.001
    end

    # Taken from a real reply: the model's StructuredOutput call held the
    # literal two characters `\n` and rendered as one line.
    test "a reply the model escaped twice arrives with its line breaks" do
      text = ~S|Reviewed the check-in.\n\n- QA is waiting on (\"Subscription Sync\").|

      assert {:ok, result} = complete_end_turn(text)

      assert result.messages ==
               [
                 Message.assistant(
                   ~s|Reviewed the check-in.\n\n- QA is waiting on ("Subscription Sync").|
                 )
               ]
    end

    test "text beside a tool call is unescaped the same way" do
      text = ~S|Checking.\nOne moment.|

      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            {envelope(%{
               "stop_reason" => "tool_use",
               "text" => text,
               "tool_calls" => [%{"call_id" => "c1", "name" => "read", "arguments" => %{}}]
             }), 0}
          end)
      }

      assert {:ok, %{messages: [%Message{content: [%{type: "text", text: unescaped} | _]}]}} =
               ClaudeCode.complete([Message.user("Hi")], [], config)

      assert unescaped == "Checking.\nOne moment."
    end

    test "a reply with real line breaks keeps a literal \\n it quotes" do
      text = "Use `\\n` in the regex.\nThat is all."

      assert {:ok, result} = complete_end_turn(text)
      assert result.messages == [Message.assistant(text)]
    end

    test "a one-line reply with a bare quote is left as written" do
      text = ~S|Split on "\n" here.|

      assert {:ok, result} = complete_end_turn(text)
      assert result.messages == [Message.assistant(text)]
    end

    # Claude Code bills a request in three parts and reports `input_tokens` as
    # the uncached remainder alone. Measured against the real CLI on 2026-09-21:
    # a turn carrying a 3.6KB appended system prompt answered `input_tokens: 4`
    # beside a cache_creation of 19,628 and a cache_read of 25,914 — four tokens
    # against a real input of forty-five thousand. One agent turn through a
    # harness reported 26 against an actual 826,876.
    #
    # So a caller totalling `input_tokens` to bill somebody, or to judge whether
    # a prompt is too long, reads a number four orders of magnitude out — and
    # the cache hit `--resume` exists to buy is invisible in the one place a
    # caller looks for it.
    test "usage carries the cached halves, not just the uncached remainder" do
      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            {envelope(
               %{"stop_reason" => "end_turn", "text" => "ok", "tool_calls" => []},
               usage: %{
                 "input_tokens" => 4,
                 "output_tokens" => 11,
                 "cache_creation_input_tokens" => 19_628,
                 "cache_read_input_tokens" => 25_914
               }
             ), 0}
          end)
      }

      assert {:ok, result} = ClaudeCode.complete([Message.user("Hi")], [], config)

      assert result.usage == %{
               input_tokens: 4,
               output_tokens: 11,
               cache_creation_input_tokens: 19_628,
               cache_read_input_tokens: 25_914
             }
    end

    # Absent and zero are the same to a total, and a provider that does not
    # report caching must not read as one whose cache never hit.
    test "a response without cache figures reports zeroes rather than nil" do
      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            {envelope(%{"stop_reason" => "end_turn", "text" => "ok", "tool_calls" => []},
               usage: %{"input_tokens" => 5, "output_tokens" => 7}
             ), 0}
          end)
      }

      assert {:ok, result} = ClaudeCode.complete([Message.user("Hi")], [], config)
      assert result.usage.cache_read_input_tokens == 0
      assert result.usage.cache_creation_input_tokens == 0
    end

    # The shape the schema now asks for: the arguments themselves, not a string
    # holding them.
    #
    # Double-encoding is fine for a browser selector and unworkable for source
    # code — quotes, newlines and regex backslashes have to survive being
    # escaped, embedded and parsed back out. Measured 2026-09-08: a coding agent
    # produced three messages in fifteen minutes and all three were
    # `invalid Claude Code arguments_json`, no files changed, 4 tool calls
    # against 1,847 messages across the fleet.
    #
    # The payload here is the one that broke it: a module with a regex in it.
    test "reads tool arguments as an object" do
      tool_defs = [
        %{
          name: "write_project_file",
          description: "Write a file",
          input_schema: %{type: "object", properties: %{path: %{type: "string"}}}
        }
      ]

      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            structured = %{
              "stop_reason" => "tool_use",
              "text" => "",
              "tool_calls" => [
                %{
                  "call_id" => "call_1",
                  "name" => "write_project_file",
                  "arguments" => %{
                    "path" => "lib/a.ex",
                    "content" => "defmodule A do\n  @re ~r/\\d+/\nend"
                  }
                }
              ]
            }

            {envelope(structured), 0}
          end)
      }

      assert {:ok, result} =
               ClaudeCode.complete([Message.user("write it")], tool_defs, config)

      assert result.stop_reason == :tool_use

      assert result.messages == [
               Message.assistant_blocks([
                 %{
                   type: "tool_use",
                   id: "call_1",
                   name: "write_project_file",
                   input: %{
                     "path" => "lib/a.ex",
                     "content" => "defmodule A do\n  @re ~r/\\d+/\nend"
                   }
                 }
               ])
             ]
    end

    test "returns tool_use blocks when Claude Code requests tools" do
      tool_defs = [
        %{
          name: "search_examples",
          description: "Find similar inbox examples",
          input_schema: %{type: "object", properties: %{query: %{type: "string"}}}
        }
      ]

      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            structured = %{
              "stop_reason" => "tool_use",
              "text" => "",
              "tool_calls" => [
                %{
                  "call_id" => "call_1",
                  "name" => "search_examples",
                  "arguments" => %{"query" => "waiting on vendor", "limit" => 2}
                }
              ]
            }

            {envelope(structured), 0}
          end)
      }

      assert {:ok, result} =
               ClaudeCode.complete([Message.user("Help me triage this")], tool_defs, config)

      assert result.stop_reason == :tool_use

      assert result.messages == [
               Message.assistant_blocks([
                 %{
                   type: "tool_use",
                   id: "call_1",
                   name: "search_examples",
                   input: %{"query" => "waiting on vendor", "limit" => 2}
                 }
               ])
             ]
    end

    test "returns tool_use rather than a completed answer for a prompt that would need a tool" do
      # Contract regression test for the tool-suppression design (see the
      # module doc): given the exact envelope shape the real CLI returns
      # when `--tools ""` prevents it from just doing the work itself, our
      # parsing must surface stop_reason: :tool_use, not silently normalize
      # it into a finished answer. The real, live version of this same
      # assertion (actually invoking `claude` with tool suppression flags)
      # lives in claude_code_live_test.exs.
      tool_defs = [
        %{
          name: "get_weather",
          description: "Get current weather for a city",
          input_schema: %{type: "object", properties: %{location: %{type: "string"}}}
        }
      ]

      config = %{
        model: "claude-haiku-4-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            structured = %{
              "stop_reason" => "tool_use",
              "text" => "I'll get the current weather for Boston, MA.",
              "tool_calls" => [
                %{
                  "call_id" => "call_1",
                  "name" => "get_weather",
                  "arguments" => %{"location" => "Boston, MA"}
                }
              ]
            }

            {envelope(structured), 0}
          end)
      }

      assert {:ok, result} =
               ClaudeCode.complete(
                 [Message.user("What is the current weather in Boston, MA?")],
                 tool_defs,
                 config
               )

      assert result.stop_reason == :tool_use
      assert [%Message{content: blocks}] = result.messages
      assert Enum.any?(blocks, &match?(%{type: "tool_use", name: "get_weather"}, &1))
    end

    test "builds a structured prompt that includes system prompt and tool definitions" do
      parent = self()

      config = %{
        model: "claude-sonnet-5",
        system_prompt: "You are an inbox triage harness.",
        command_runner:
          fake_runner(fn args, _opts ->
            send(parent, {:claude_args, args})
            {envelope(%{"stop_reason" => "end_turn", "text" => "OK", "tool_calls" => []}), 0}
          end)
      }

      tool_defs = [
        %{
          name: "search_examples",
          description: "Find similar inbox examples",
          input_schema: %{type: "object", properties: %{query: %{type: "string"}}}
        }
      ]

      messages = [
        Message.user("Need a decision"),
        Message.assistant_blocks([
          %{
            type: "tool_use",
            id: "call_1",
            name: "search_examples",
            input: %{"query" => "urgent"}
          },
          %{type: "text", text: "Checking similar examples."}
        ]),
        Message.tool_results([
          %{type: "tool_result", tool_use_id: "call_1", content: "Found two examples"}
        ])
      ]

      assert {:ok, _result} = ClaudeCode.complete(messages, tool_defs, config)

      assert_receive {:claude_args, args}

      # `--append-system-prompt` carries the config's system_prompt as a
      # real system-level instruction; the prompt (last arg, for the
      # injected test runner) still embeds it in the transcript payload too,
      # same as Codex.
      assert "--append-system-prompt" in args
      assert "You are an inbox triage harness." in args
      assert "--tools" in args
      assert "" in args
      assert "--strict-mcp-config" in args
      assert "--safe-mode" in args

      prompt = List.last(args)

      assert prompt =~ "You are acting as the model backend for Alloy"
      assert prompt =~ "You are an inbox triage harness."
      assert prompt =~ "\"name\":\"search_examples\""
      assert prompt =~ "\"tool_result\""
      assert prompt =~ "\"Found two examples\""
    end

    test "returns a helpful error when Claude Code output violates the contract" do
      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            bad_structured = %{
              "stop_reason" => "end_turn",
              "text" => "oops",
              "tool_calls" => [%{"call_id" => "call_1", "name" => "bad", "arguments" => %{}}]
            }

            {envelope(bad_structured), 0}
          end)
      }

      assert {:error, %Error{message: reason}} =
               ClaudeCode.complete([Message.user("Hi")], [], config)

      assert reason =~ "tool_calls"
    end

    # There is one shape now and one failure: arguments that are not an object.
    # The old test covered a string of invalid JSON, which the schema no longer
    # permits and nothing decodes.
    test "returns a helpful error when arguments are not an object" do
      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            structured = %{
              "stop_reason" => "tool_use",
              "text" => "",
              "tool_calls" => [
                %{
                  "call_id" => "call_1",
                  "name" => "search_examples",
                  "arguments" => "not an object"
                }
              ]
            }

            {envelope(structured), 0}
          end)
      }

      assert {:error, %Error{message: reason}} =
               ClaudeCode.complete([Message.user("Hi")], [], config)

      assert reason =~ "must be an object"
    end

    test "trusts is_error: false in the envelope even if the process exits non-zero" do
      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            {envelope(%{"stop_reason" => "end_turn", "text" => "Recovered", "tool_calls" => []}),
             1}
          end)
      }

      assert {:ok, result} = ClaudeCode.complete([Message.user("Hi")], [], config)
      assert result.messages == [Message.assistant("Recovered")]
    end

    test "returns an error built from the envelope's result field when is_error is true" do
      config = %{
        model: "totally-bogus-model",
        command_runner:
          fake_runner(fn _args, _opts ->
            {error_envelope("There's an issue with the selected model."), 1}
          end)
      }

      assert {:error, %Error{message: reason}} =
               ClaudeCode.complete([Message.user("Hi")], [], config)

      assert reason =~ "There's an issue with the selected model."
    end

    test "falls back to a generic error when stdout has no JSON result object" do
      config = %{
        model: "claude-sonnet-5",
        command_runner: fake_runner(fn _args, _opts -> {"not json at all", 1} end)
      }

      assert {:error, %Error{message: reason}} =
               ClaudeCode.complete([Message.user("Hi")], [], config)

      assert reason =~ "claude exec failed"
    end

    test "scans backward past stray non-JSON stdout lines for the result object" do
      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            noisy =
              "some stray banner line\n" <>
                envelope(%{"stop_reason" => "end_turn", "text" => "clean", "tool_calls" => []})

            {noisy, 0}
          end)
      }

      assert {:ok, result} = ClaudeCode.complete([Message.user("Hi")], [], config)
      assert result.messages == [Message.assistant("clean")]
    end

    test "passes the prompt via stdin for the real shell-backed runner" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-claude-code-provider-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      script_path = Path.join(temp_dir, "fake-claude.sh")

      File.write!(
        script_path,
        """
        #!/bin/sh
        set -eu

        prompt="$(cat)"

        case "$prompt" in
          *"Need a decision"*) ;;
          *)
            echo "missing prompt on stdin" >&2
            exit 42
            ;;
        esac

        printf '%s' '#{envelope(%{"stop_reason" => "end_turn", "text" => "stdin ok", "tool_calls" => []})}'
        """
      )

      File.chmod!(script_path, 0o755)

      config = %{model: "claude-sonnet-5", claude_bin: script_path}

      assert {:ok, result} = ClaudeCode.complete([Message.user("Need a decision")], [], config)
      assert result.messages == [Message.assistant("stdin ok")]
    end

    test "never receives a positional prompt or stdin marker for the real shell-backed runner" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-claude-code-provider-noarg-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      script_path = Path.join(temp_dir, "fake-claude.sh")

      File.write!(
        script_path,
        """
        #!/bin/sh
        set -eu

        # A real `claude -p` invocation reads the prompt from stdin with no
        # positional argument at all. If this provider ever regresses to
        # appending a stray "-" (a marker some other CLIs use), that would
        # arrive here as the last positional arg and get caught below.
        for arg in "$@"; do
          if [ "$arg" = "-" ]; then
            echo "unexpected positional '-' argument" >&2
            exit 43
          fi
        done

        cat > /dev/null
        printf '%s' '#{envelope(%{"stop_reason" => "end_turn", "text" => "no positional arg", "tool_calls" => []})}'
        """
      )

      File.chmod!(script_path, 0o755)

      config = %{model: "claude-sonnet-5", claude_bin: script_path}

      assert {:ok, result} = ClaudeCode.complete([Message.user("Hi")], [], config)
      assert result.messages == [Message.assistant("no positional arg")]
    end

    test "stray stderr output does not corrupt the stdout JSON envelope" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-claude-code-provider-stderr-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      script_path = Path.join(temp_dir, "fake-claude.sh")

      File.write!(
        script_path,
        """
        #!/bin/sh
        cat > /dev/null
        echo "some warning banner" >&2
        echo "another line of noise" >&2
        printf '%s' '#{envelope(%{"stop_reason" => "end_turn", "text" => "clean", "tool_calls" => []})}'
        """
      )

      File.chmod!(script_path, 0o755)

      config = %{model: "claude-sonnet-5", claude_bin: script_path}

      assert {:ok, result} = ClaudeCode.complete([Message.user("Hi")], [], config)
      assert result.messages == [Message.assistant("clean")]
    end

    test "collects output even when the process exits before os_pid can be read" do
      # Regression: Port.info(port, :os_pid) returns nil when the spawned
      # process has already exited. The output and exit_status messages are
      # still in the mailbox, so a fast-exiting claude must succeed, not
      # error with "port closed before os_pid was available". The race is
      # timing-dependent; the instant-exit script plus repetition makes it
      # likely under the old code and proves the nil branch under the new.
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-claude-code-provider-fastexit-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      script_path = Path.join(temp_dir, "fast-claude.sh")

      File.write!(
        script_path,
        """
        #!/bin/sh
        cat > /dev/null
        printf '%s' '#{envelope(%{"stop_reason" => "end_turn", "text" => "fast exit", "tool_calls" => []})}'
        """
      )

      File.chmod!(script_path, 0o755)

      config = %{model: "claude-sonnet-5", claude_bin: script_path}

      for _run <- 1..20 do
        assert {:ok, result} = ClaudeCode.complete([Message.user("Hi")], [], config)
        assert result.messages == [Message.assistant("fast exit")]
      end
    end

    test "returns a timeout error instead of hanging when the real shell-backed run exceeds timeout_ms" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-claude-code-provider-timeout-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      script_path = Path.join(temp_dir, "slow-claude.sh")

      File.write!(script_path, """
      #!/bin/sh
      # Drain stdin so the shell redirect completes, then hang.
      cat > /dev/null
      sleep 30
      """)

      File.chmod!(script_path, 0o755)

      config = %{
        model: "claude-sonnet-5",
        claude_bin: script_path,
        timeout_ms: 200
      }

      started_at = System.monotonic_time(:millisecond)
      result = ClaudeCode.complete([Message.user("hang")], [], config)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert {:error, %Error{message: reason}} = result
      assert reason =~ "timed out"
      # Generous slack for TERM/KILL grace window and CI noise.
      assert elapsed < 5_000,
             "expected timeout to fire within ~200ms + grace, took #{elapsed}ms"
    end

    test "receive_timeout caps a larger timeout_ms for the real shell-backed run" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-claude-code-provider-receive-timeout-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      script_path = Path.join(temp_dir, "slow-claude.sh")

      File.write!(script_path, """
      #!/bin/sh
      cat > /dev/null
      sleep 30
      """)

      File.chmod!(script_path, 0o755)

      config = %{
        model: "claude-sonnet-5",
        claude_bin: script_path,
        timeout_ms: 30_000,
        receive_timeout: 150
      }

      started_at = System.monotonic_time(:millisecond)
      result = ClaudeCode.complete([Message.user("deadline")], [], config)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert {:error,
              %Error{kind: :timeout, message: "claude exec timed out after 150ms with no output"}} =
               result

      assert elapsed < 5_000,
             "expected receive_timeout to cap the port timeout, took #{elapsed}ms"
    end

    # eb09b076: a slow reply on a large context kept streaming and was killed at
    # three minutes anyway, every turn.
    test "a run that keeps writing is not cut off at timeout_ms" do
      script =
        fake_cli("""
        i=0
        while [ $i -lt 12 ]; do
          printf '%s\\n' '{"type":"system","subtype":"status"}'
          sleep 0.1
          i=$((i+1))
        done
        printf '%s\\n' '#{envelope(%{"stop_reason" => "end_turn", "text" => "slow but steady", "tool_calls" => []})}'
        """)

      config = %{model: "claude-sonnet-5", claude_bin: script, timeout_ms: 400}

      assert {:ok, result} = ClaudeCode.complete([Message.user("go")], [], config)
      assert result.messages == [Message.assistant("slow but steady")]
    end

    test "a run that writes forever still stops at max_run_ms" do
      script =
        fake_cli("""
        while true; do
          printf '%s\\n' '{"type":"system","subtype":"status"}'
          sleep 0.1
        done
        """)

      config = %{model: "claude-sonnet-5", claude_bin: script, timeout_ms: 400, max_run_ms: 800}

      started_at = System.monotonic_time(:millisecond)
      result = ClaudeCode.complete([Message.user("go")], [], config)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert {:error,
              %Error{
                kind: :timeout,
                message:
                  "claude exec timed out after 800ms, its limit for one run, while still writing"
              }} = result

      assert elapsed < 5_000
    end

    defp fake_cli(body) do
      dir = Path.join(System.tmp_dir!(), "alloy-cc-fake-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      script = Path.join(dir, "claude.sh")
      File.write!(script, "#!/bin/sh\ncat > /dev/null\n" <> body)
      File.chmod!(script, 0o755)
      script
    end
  end

  describe "session continuation (--resume)" do
    test "a first call has no session to resume, and returns provider_state for the next one" do
      parent = self()

      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn args, _opts ->
            send(parent, {:args, args})

            {envelope(
               %{"stop_reason" => "end_turn", "text" => "All done", "tool_calls" => []},
               session_id: "sess_abc123"
             ), 0}
          end)
      }

      messages = [Message.user("Hi")]
      assert {:ok, result} = ClaudeCode.complete(messages, [], config)

      assert_receive {:args, args}
      refute "--resume" in args

      reply = List.first(result.messages)

      assert result.provider_state == %{
               session_id: "sess_abc123",
               sent_upto: 2,
               prefix_hash: :erlang.phash2(messages ++ [reply]),
               tools_hash: :erlang.phash2([])
             }
    end

    test "a second call whose prefix still matches resumes with only the new messages" do
      parent = self()

      messages1 = [Message.user("Hi")]

      config1 = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn args, _opts ->
            send(parent, {:call, args})

            {envelope(
               %{"stop_reason" => "end_turn", "text" => "First reply", "tool_calls" => []},
               session_id: "sess_1"
             ), 0}
          end)
      }

      assert {:ok, result1} = ClaudeCode.complete(messages1, [], config1)

      reply1 = List.first(result1.messages)
      messages2 = messages1 ++ [reply1, Message.user("Follow-up question")]

      config2 = %{
        model: "claude-sonnet-5",
        provider_state: result1.provider_state,
        command_runner:
          fake_runner(fn args, _opts ->
            send(parent, {:call, args})

            {envelope(
               %{"stop_reason" => "end_turn", "text" => "Second reply", "tool_calls" => []},
               session_id: "sess_1"
             ), 0}
          end)
      }

      assert {:ok, result2} = ClaudeCode.complete(messages2, [], config2)

      assert_receive {:call, first_args}
      refute "--resume" in first_args

      assert_receive {:call, second_args}
      assert "--resume" in second_args
      assert "sess_1" in second_args

      prompt2 = List.last(second_args)
      refute prompt2 =~ "\"Hi\""
      refute prompt2 =~ "You are acting as the model backend for Alloy"
      assert prompt2 =~ "Continuing the same conversation"
      assert prompt2 =~ "Follow-up question"

      assert result2.provider_state == %{
               session_id: "sess_1",
               sent_upto: length(messages2) + 1,
               prefix_hash: :erlang.phash2(messages2 ++ [List.first(result2.messages)]),
               tools_hash: :erlang.phash2([])
             }
    end

    # Re-sending every tool definition on every resumed call filled a
    # resumed session to its compaction limit in hours.
    test "a resumed call sends the tool definitions only when they changed" do
      parent = self()
      tool = %{name: "read_file", description: "Read a file", input_schema: %{type: "object"}}
      other = %{name: "write_file", description: "Write a file", input_schema: %{type: "object"}}

      runner =
        fake_runner(fn args, _opts ->
          send(parent, {:call, args})

          {envelope(
             %{"stop_reason" => "end_turn", "text" => "ok", "tool_calls" => []},
             session_id: "sess_t"
           ), 0}
        end)

      messages1 = [Message.user("Hi")]
      assert {:ok, r1} = ClaudeCode.complete(messages1, [tool], %{command_runner: runner})
      assert_receive {:call, first}
      assert List.last(first) =~ "read_file"

      messages2 = messages1 ++ [List.first(r1.messages), Message.user("Again")]

      assert {:ok, r2} =
               ClaudeCode.complete(messages2, [tool], %{
                 command_runner: runner,
                 provider_state: r1.provider_state
               })

      assert_receive {:call, second}
      assert "--resume" in second
      refute List.last(second) =~ "available_tools"

      messages3 = messages2 ++ [List.first(r2.messages), Message.user("New tools")]

      assert {:ok, _} =
               ClaudeCode.complete(messages3, [tool, other], %{
                 command_runner: runner,
                 provider_state: r2.provider_state
               })

      assert_receive {:call, third}
      assert "--resume" in third
      assert List.last(third) =~ "available_tools"
      assert List.last(third) =~ "write_file"
    end

    test "a prefix mismatch falls back to a fresh full resend rather than trusting a stale resume" do
      parent = self()

      config = %{
        model: "claude-sonnet-5",
        # Simulates history having been rewritten since this session_id was
        # captured (compaction, most likely) - the hash cannot possibly match
        # the real prefix below.
        provider_state: %{
          session_id: "sess_stale",
          sent_upto: 1,
          prefix_hash: :erlang.phash2(["not the real prefix"])
        },
        command_runner:
          fake_runner(fn args, _opts ->
            send(parent, {:args, args})

            {envelope(
               %{"stop_reason" => "end_turn", "text" => "Fresh again", "tool_calls" => []},
               session_id: "sess_new"
             ), 0}
          end)
      }

      assert {:ok, result} = ClaudeCode.complete([Message.user("Hi")], [], config)
      assert result.provider_state.session_id == "sess_new"

      assert_receive {:args, args}
      refute "--resume" in args
      refute "sess_stale" in args
      assert List.last(args) =~ "You are acting as the model backend for Alloy"
    end
  end

  describe "stream/4" do
    test "replays the final assistant text through the callback" do
      parent = self()

      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn _args, _opts ->
            {envelope(%{"stop_reason" => "end_turn", "text" => "Chunk me", "tool_calls" => []}),
             0}
          end)
      }

      assert {:ok, result} =
               ClaudeCode.stream([Message.user("Hi")], [], config, fn chunk ->
                 send(parent, {:chunk, chunk})
                 :ok
               end)

      assert_receive {:chunk, "Chunk me"}
      assert result.messages == [Message.assistant("Chunk me")]
    end

    test "streams the reply text out of the StructuredOutput deltas as they arrive" do
      parent = self()
      final = "Plums are \"stone\" fruits.\nPrunes 🍑 are dried plums."

      # The shape `stream-json --include-partial-messages` delivers under
      # `--json-schema`: a thinking block, then the tool input in fragments cut
      # mid-escape, mid-`\u`, and between a surrogate pair's halves.
      fragments = [
        ~s({"stop_reason": "end_tur),
        ~s(n", "text": "Plums are \\"sto),
        ~s(ne\\" fruits.\\),
        ~s(nPrunes \\ud83),
        ~s(c\\udf),
        ~s(51 are dried plums.", "tool_calls": []})
      ]

      stdout =
        [
          stream_event(%{
            "type" => "content_block_start",
            "content_block" => %{"type" => "thinking"}
          }),
          stream_event(%{
            "type" => "content_block_delta",
            "delta" => %{"type" => "thinking_delta", "thinking" => "The user wants plums."}
          }),
          stream_event(%{
            "type" => "content_block_start",
            "content_block" => %{"type" => "tool_use", "name" => "StructuredOutput"}
          })
          | Enum.map(fragments, fn fragment ->
              stream_event(%{
                "type" => "content_block_delta",
                "delta" => %{"type" => "input_json_delta", "partial_json" => fragment}
              })
            end)
        ] ++
          [envelope(%{"stop_reason" => "end_turn", "text" => final, "tool_calls" => []})]

      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn args, _opts ->
            send(parent, {:args, args})
            Enum.join(stdout, "\n") <> "\n"
          end)
      }

      assert {:ok, result} =
               ClaudeCode.stream([Message.user("Plums?")], [], config, fn chunk ->
                 send(parent, {:chunk, chunk})
                 :ok
               end)

      assert_receive {:args, args}

      assert ["--output-format", "stream-json", "--verbose", "--include-partial-messages" | _] =
               Enum.drop_while(args, &(&1 != "--output-format"))

      chunks = collect_chunks([])
      assert length(chunks) > 1
      assert Enum.join(chunks) == final
      assert result.messages == [Message.assistant(final)]
    end

    test "complete/3 reads stream-json too, so it can see what the model does mid-turn" do
      parent = self()

      config = %{
        model: "claude-sonnet-5",
        command_runner:
          fake_runner(fn args, _opts ->
            send(parent, {:args, args})
            envelope(%{"stop_reason" => "end_turn", "text" => "ok", "tool_calls" => []})
          end)
      }

      assert {:ok, result} = ClaudeCode.complete([Message.user("Hi")], [], config)
      assert result.messages == [Message.assistant("ok")]
      assert_receive {:args, args}

      assert ["--output-format", "stream-json" | _] =
               Enum.drop_while(args, &(&1 != "--output-format"))
    end
  end

  describe "a tool the model calls natively" do
    @read_tool %{
      name: "read",
      description: "Read a file",
      input_schema: %{type: "object", properties: %{file_path: %{type: "string"}}}
    }

    # The shape from a real session (metric_flow coder 965c52a9): the CLI's
    # loop answers a native call with a refusal the model then acts on.
    defp native_call_output(name, input) do
      [
        assistant_event([
          %{"type" => "tool_use", "id" => "toolu_native", "name" => name, "input" => input}
        ]),
        Jason.encode!(%{
          "type" => "user",
          "message" => %{
            "content" => [
              %{
                "type" => "tool_result",
                "tool_use_id" => "toolu_native",
                "content" =>
                  "<tool_use_error>Error: No such tool available: #{name}</tool_use_error>"
              }
            ]
          }
        }),
        envelope(%{
          "stop_reason" => "end_turn",
          "text" => "Every tool call fails; this looks like a total tool-execution outage.",
          "tool_calls" => []
        })
      ]
      |> Enum.join("\n")
    end

    defp assistant_event(blocks),
      do: Jason.encode!(%{"type" => "assistant", "message" => %{"content" => blocks}})

    test "one Alloy has is run as a tool call, never refused, and the session is not resumed" do
      earlier = [Message.user("earlier"), Message.assistant("ok")]

      config = %{
        model: "claude-sonnet-5",
        provider_state: %{
          session_id: "sess_old",
          sent_upto: 2,
          prefix_hash: :erlang.phash2(earlier)
        },
        command_runner:
          fake_runner(fn _args, _opts ->
            native_call_output("read", %{"file_path" => "lib/a.ex"})
          end)
      }

      assert {:ok, result} =
               ClaudeCode.complete(earlier ++ [Message.user("go")], [@read_tool], config)

      assert result.stop_reason == :tool_use

      assert result.messages == [
               Message.assistant_blocks([
                 %{
                   type: "tool_use",
                   id: "toolu_native",
                   name: "read",
                   input: %{"file_path" => "lib/a.ex"}
                 }
               ])
             ]

      refute inspect(result.messages) =~ "outage"

      assert result.provider_state == %{
               session_id: nil,
               sent_upto: nil,
               prefix_hash: nil,
               tools_hash: nil
             }
    end

    test "one Alloy does not have leaves the reply alone but does not resume the session" do
      config = %{
        model: "claude-sonnet-5",
        command_runner: fake_runner(fn _args, _opts -> native_call_output("health", %{}) end)
      }

      assert {:ok, result} = ClaudeCode.complete([Message.user("go")], [@read_tool], config)
      assert result.stop_reason == :end_turn

      assert result.provider_state == %{
               session_id: nil,
               sent_upto: nil,
               prefix_hash: nil,
               tools_hash: nil
             }
    end

    test "its input is not streamed as the reply" do
      parent = self()

      stdout =
        [
          stream_event(%{
            "type" => "content_block_start",
            "content_block" => %{"type" => "tool_use", "name" => "run_script"}
          }),
          stream_event(%{
            "type" => "content_block_delta",
            "delta" => %{
              "type" => "input_json_delta",
              "partial_json" => ~s({"text": "not the reply"})
            }
          }),
          envelope(%{"stop_reason" => "end_turn", "text" => "the reply", "tool_calls" => []})
        ]
        |> Enum.join("\n")

      config = %{model: "claude-sonnet-5", command_runner: fake_runner(fn _, _ -> stdout end)}

      assert {:ok, _} =
               ClaudeCode.stream([Message.user("go")], [], config, &send(parent, {:chunk, &1}))

      assert collect_chunks([]) == ["the reply"]
    end

    test "the real CLI is stopped before it can refuse, rather than left to finish" do
      temp_dir =
        Path.join(System.tmp_dir!(), "alloy-cc-native-#{System.unique_integer([:positive])}")

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      line =
        assistant_event([
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "read", "input" => %{}}
        ])

      script = Path.join(temp_dir, "fake-claude.sh")

      # Writes the native call, then would sit for a minute before refusing —
      # a run that is not stopped makes this test time out.
      File.write!(script, """
      #!/bin/sh
      cat > /dev/null
      printf '%s\\n' '#{line}'
      sleep 60
      """)

      File.chmod!(script, 0o755)

      config = %{model: "claude-sonnet-5", claude_bin: script, timeout_ms: 30_000}

      {elapsed_us, result} =
        :timer.tc(fn -> ClaudeCode.complete([Message.user("go")], [@read_tool], config) end)

      assert {:ok, %{stop_reason: :tool_use}} = result
      assert elapsed_us < 10_000_000
    end
  end

  describe "StreamJson.text_prefix/1" do
    alias Alloy.Provider.ClaudeCode.StreamJson

    test "is nil until the text value starts" do
      assert StreamJson.text_prefix(~s({"stop_reason": "tool_use", "te)) == nil
      assert StreamJson.text_prefix(~s({"stop_reason": "tool_use", "text": )) == nil
    end

    test "ignores a text key nested in tool call arguments" do
      json =
        ~s({"stop_reason": "tool_use", "tool_calls": [{"name": "write", "arguments": {"text": "no"}}], "text": "yes)

      assert StreamJson.text_prefix(json) == "yes"
    end

    test "does not take a value that happens to be the string text for the key" do
      assert StreamJson.text_prefix(~s({"stop_reason": "text", "text": "real)) == "real"
    end

    test "holds back an escape that has not finished arriving" do
      assert StreamJson.text_prefix(~s({"text": "a\\)) == "a"
      assert StreamJson.text_prefix(~s({"text": "a\\u00)) == "a"
      assert StreamJson.text_prefix(~s({"text": "a\\u00e9)) == "aé"
      assert StreamJson.text_prefix(~s({"text": "a\\ud83c)) == "a"
      assert StreamJson.text_prefix(~s({"text": "a\\ud83c\\udf51)) == "a🍑"
    end
  end

  defp stream_event(event), do: Jason.encode!(%{"type" => "stream_event", "event" => event})

  defp collect_chunks(acc) do
    receive do
      {:chunk, chunk} -> collect_chunks([chunk | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp complete_end_turn(text) do
    config = %{
      model: "claude-sonnet-5",
      command_runner:
        fake_runner(fn _args, _opts ->
          {envelope(%{"stop_reason" => "end_turn", "text" => text, "tool_calls" => []}), 0}
        end)
    }

    ClaudeCode.complete([Message.user("Hi")], [], config)
  end

  defp fake_runner(fun) do
    fn _cmd, args, opts ->
      case fun.(args, opts) do
        {output, status} when is_binary(output) and is_integer(status) -> {output, status}
        output when is_binary(output) -> {output, 0}
      end
    end
  end

  defp envelope(structured_output, opts \\ []) do
    Jason.encode!(%{
      "type" => "result",
      "subtype" => Keyword.get(opts, :subtype, "success"),
      "is_error" => false,
      "result" => Jason.encode!(structured_output),
      "structured_output" => structured_output,
      "session_id" => Keyword.get(opts, :session_id, "sess_test"),
      "total_cost_usd" => Keyword.get(opts, :total_cost_usd, 0.001),
      "duration_ms" => Keyword.get(opts, :duration_ms, 100),
      "usage" => Keyword.get(opts, :usage, %{"input_tokens" => 5, "output_tokens" => 7})
    })
  end

  defp error_envelope(result_text, opts \\ []) do
    Jason.encode!(%{
      "type" => "result",
      "subtype" => Keyword.get(opts, :subtype, "success"),
      "is_error" => true,
      "result" => result_text,
      "session_id" => Keyword.get(opts, :session_id, "sess_err"),
      "usage" => %{}
    })
  end
end
