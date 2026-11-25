defmodule Alloy.Provider.CodexTest do
  use ExUnit.Case, async: true

  alias Alloy.Agent.{Config, State, Turn}
  alias Alloy.Message
  alias Alloy.Provider.{Codex, CodexRunner, Error, Retry}

  describe "opt-in continuation" do
    test "the agent loop resumes after executing a tool" do
      parent = self()

      tool =
        Alloy.Tool.inline(
          name: "echo",
          description: "Echo a value",
          input_schema: %{type: "object", properties: %{}, additionalProperties: false},
          execute: fn _input, _context -> {:ok, "tool-evidence"} end
        )

      runner =
        fake_runner(fn args, _opts, path ->
          resumed? = Enum.take(args, 2) == ["exec", "resume"]
          send(parent, {:loop_call, resumed?, List.last(args)})

          payload =
            if resumed? do
              %{stop_reason: "end_turn", text: "completed", tool_calls: []}
            else
              %{
                stop_reason: "tool_use",
                text: "",
                tool_calls: [%{call_id: "call-1", name: "echo", arguments_json: "{}"}]
              }
            end

          File.write!(path, Jason.encode!(payload))
          ~s({"type":"thread.started","thread_id":"thread-1"}\n)
        end)

      config =
        Config.from_opts(
          provider:
            {Codex,
             %{
               model: "test-model",
               persist_session: true,
               workdir: System.tmp_dir!(),
               command_runner: runner
             }},
          tools: [tool],
          max_turns: 2
        )

      result =
        config
        |> State.init([Message.user("initial-task")])
        |> Turn.run_loop()

      assert result.status == :completed
      assert result.turn == 2
      assert_receive {:loop_call, false, _prompt}
      assert_receive {:loop_call, true, prompt}
      assert prompt =~ "tool-evidence"
      refute prompt =~ "initial-task"
    end

    defp session_config do
      parent = self()

      %{
        model: "test-model",
        persist_session: true,
        workdir: System.tmp_dir!(),
        command_runner:
          fake_runner(fn args, _opts, output_path ->
            send(parent, {:invocation, args})

            File.write!(
              output_path,
              ~s({"stop_reason":"end_turn","text":"first-reply","tool_calls":[]})
            )

            ~s({"type":"thread.started","thread_id":"thread-1"}\n)
          end)
      }
    end

    test "restored continuation state merges and saves without duplicate JSON keys" do
      config = session_config()
      messages = [Message.user("original")]
      assert {:ok, first} = Codex.complete(messages, [], config)
      assert_receive {:invocation, _args}
      restored = first.provider_state |> Jason.encode!() |> Jason.decode!()
      history = messages ++ first.messages ++ [Message.user("next")]

      state =
        Config.from_opts(provider: {Codex, Map.put(config, :provider_state, restored)})
        |> State.init(history)
        |> Turn.run_loop()

      assert state.status == :completed
      assert_receive {:invocation, ["exec", "resume" | _rest]}
      saved = state.provider_state |> Jason.encode!(maps: :strict) |> Jason.decode!()
      assert saved["codex_session"]["count"] == length(history) + 1
      config = Map.put(config, :provider_state, saved)

      assert {:ok, _result} =
               Codex.complete(state.messages ++ [Message.user("third")], [], config)

      assert_receive {:invocation, ["exec", "resume" | _rest] = args}
      assert List.last(args) =~ "third"
      refute List.last(args) =~ "next"
      refute List.last(args) =~ "original"

      cleared =
        Config.from_opts(provider: {Codex, Map.put(config, :persist_session, false)})
        |> State.init(state.messages ++ [Message.user("ephemeral")])
        |> Turn.run_loop()

      assert_receive {:invocation, args}
      assert "--ephemeral" in args

      assert cleared.provider_state |> Jason.encode!(maps: :strict) |> Jason.decode!() == %{
               "codex_session" => nil
             }
    end

    test "resumes only the new wire history and ignores loop-added provenance" do
      config = session_config()
      initial = [Message.user("original-input")]
      assert {:ok, first} = Codex.complete(initial, [], config)
      assert_receive {:invocation, fresh_args}
      refute "--ephemeral" in fresh_args

      stamped =
        Enum.map(
          first.messages,
          &Map.merge(&1, %{provider: Codex, model: "test-model", origin: "same-origin"})
        )

      history = initial ++ stamped ++ [Message.user("new-input")]
      config = Map.put(config, :provider_state, first.provider_state)
      assert {:ok, resumed} = Codex.complete(history, [], config)
      assert_receive {:invocation, ["exec", "resume" | _rest] = args}
      assert "thread-1" in args
      assert List.last(args) =~ "new-input"
      refute List.last(args) =~ "original-input"
      assert resumed.response_metadata.session.mode == :resumed
    end

    test "rewritten history or changed execution configuration starts fresh" do
      config = session_config()
      initial = [Message.user("original-input")]
      assert {:ok, first} = Codex.complete(initial, [], config)
      assert_receive {:invocation, _args}
      history = initial ++ first.messages ++ [Message.user("next")]
      config = Map.put(config, :provider_state, first.provider_state)

      for changed <- [
            Map.put(config, :model, "other-model"),
            Map.put(config, :system_prompt, "changed"),
            Map.put(config, :codex_home, "/other-home"),
            Map.put(config, :workdir, File.cwd!()),
            Map.put(config, :codex_bin, "/other-executable"),
            Map.put(config, :config_overrides, [~s(model_reasoning_effort="low")])
          ] do
        assert {:ok, result} = Codex.complete(history, [], changed)
        assert_receive {:invocation, args}
        refute "resume" in args
        assert result.response_metadata.session.mode == :fresh
      end

      tools = [%{name: "new-tool", description: "Changed tool", input_schema: %{type: "object"}}]
      assert {:ok, result} = Codex.complete(history, tools, config)
      assert_receive {:invocation, args}
      refute "resume" in args
      assert result.response_metadata.session.mode == :fresh

      assert {:ok, _result} =
               Codex.complete([Message.user("rewritten")] ++ tl(history), [], config)

      assert_receive {:invocation, args}
      refute "resume" in args
    end

    test "default and profile calls remain ephemeral and clear continuation state" do
      for config <- [
            Map.delete(session_config(), :persist_session),
            Map.put(session_config(), :profile, "custom")
          ] do
        assert {:ok, result} = Codex.complete([Message.user("hello")], [], config)
        assert_receive {:invocation, args}
        assert "--ephemeral" in args
        assert result.provider_state == %{"codex_session" => nil}
      end
    end

    test "a missing thread id clears a previous continuation" do
      config = %{
        session_config()
        | command_runner:
            fake_runner(fn _args, _opts, path ->
              File.write!(path, ~s({"stop_reason":"end_turn","text":"ok","tool_calls":[]}))
              ""
            end)
      }

      assert {:ok, result} = Codex.complete([Message.user("hello")], [], config)
      assert result.provider_state == %{"codex_session" => nil}
    end

    test "persistent sessions require a stable working directory" do
      config = Map.delete(session_config(), :workdir)

      assert {:error, %Error{kind: :invalid_request}} =
               Codex.complete([Message.user("hello")], [], config)

      refute_received {:invocation, _args}
    end

    test "a failed resume is returned without automatically resending the full transcript" do
      config = session_config()
      messages = [Message.user("original")]
      assert {:ok, first} = Codex.complete(messages, [], config)
      assert_receive {:invocation, _args}
      parent = self()

      runner =
        fake_runner(fn args, _opts, _path ->
          send(parent, {:failed_resume, args})
          {~s({"type":"error","message":"thread not found"}\n), 1}
        end)

      config =
        config
        |> Map.put(:provider_state, first.provider_state)
        |> Map.put(:command_runner, runner)

      assert {:error, %Error{kind: :session_uncertain}} =
               Codex.complete(messages ++ first.messages ++ [Message.user("next")], [], config)

      assert_receive {:failed_resume, ["exec", "resume" | _rest]}
      refute_received {:failed_resume, _args}
    end

    test "a malformed resume is not retried against the same thread" do
      config = session_config()
      messages = [Message.user("original")]
      assert {:ok, first} = Codex.complete(messages, [], config)
      assert_receive {:invocation, _args}
      parent = self()

      runner =
        fake_runner(fn args, _opts, path ->
          send(parent, {:resume_attempt, args})
          File.write!(path, ~s({"stop_reason":"tool_use","text":"Done","tool_calls":[]}))
          ""
        end)

      config =
        config
        |> Map.put(:provider_state, first.provider_state)
        |> Map.put(:command_runner, runner)

      state =
        Config.from_opts(provider: {Codex, config}, max_retries: 1, retry_backoff_ms: 1)
        |> State.init(messages ++ first.messages ++ [Message.user("next")])

      assert {:error, %Error{kind: :session_uncertain} = error} =
               Retry.call_with_retry(
                 state,
                 Codex,
                 config,
                 false,
                 fn _text -> :ok end,
                 System.monotonic_time(:millisecond) + 5_000
               )

      refute Error.retryable?(error)
      assert_receive {:resume_attempt, ["exec", "resume" | _rest]}
      refute_received {:resume_attempt, _args}
    end

    test "a new session generation recovers without discarding history" do
      config = session_config()
      messages = [Message.user("original")]
      assert {:ok, first} = Codex.complete(messages, [], config)
      assert_receive {:invocation, _args}

      config =
        config
        |> Map.put(:provider_state, first.provider_state)
        |> Map.put(:session_generation, "recovered")

      assert {:ok, result} =
               Codex.complete(messages ++ first.messages ++ [Message.user("next")], [], config)

      assert_receive {:invocation, args}
      refute "resume" in args
      assert List.last(args) =~ "original"
      assert List.last(args) =~ "first-reply"
      assert result.response_metadata.session.mode == :fresh
    end

    test "resume enforces read-only after host overrides" do
      config = Map.put(session_config(), :config_overrides, [~s(sandbox_mode="workspace-write")])
      messages = [Message.user("original")]
      assert {:ok, first} = Codex.complete(messages, [], config)
      assert_receive {:invocation, _args}

      assert {:ok, _result} =
               Codex.complete(
                 messages ++ first.messages ++ [Message.user("next")],
                 [],
                 Map.put(config, :provider_state, first.provider_state)
               )

      assert_receive {:invocation, args}

      assert Enum.find_index(args, &(&1 == ~s(sandbox_mode="workspace-write"))) <
               Enum.find_index(args, &(&1 == ~s(sandbox_mode="read-only")))
    end

    @tag :tmp_dir
    test "a resumed subprocess timeout is not retried", %{tmp_dir: dir} do
      invocations = Path.join(dir, "invocations")

      script =
        fake_codex!(dir, """
        if [ -s "#{invocations}" ]; then
          printf 'x' >> "#{invocations}"
          sleep 30
        fi
        printf 'x' >> "#{invocations}"
        printf '%s\\n' '{"type":"thread.started","thread_id":"thread-1"}'
        """)

      config = %{
        model: "test-model",
        persist_session: true,
        workdir: dir,
        codex_home: dir,
        codex_bin: script,
        timeout_ms: 5_000
      }

      messages = [Message.user("original")]
      assert {:ok, first} = Codex.complete(messages, [], config)

      config =
        config |> Map.put(:provider_state, first.provider_state) |> Map.put(:timeout_ms, 500)

      state =
        Config.from_opts(provider: {Codex, config}, max_retries: 1, retry_backoff_ms: 1)
        |> State.init(messages ++ first.messages ++ [Message.user("next")])

      assert {:error, %Error{kind: :session_uncertain}} =
               Retry.call_with_retry(
                 state,
                 Codex,
                 config,
                 false,
                 fn _text -> :ok end,
                 System.monotonic_time(:millisecond) + 5_000
               )

      assert File.read!(invocations) == "xx"
    end
  end

  describe "complete/3" do
    test "empty tool_use is a typed retryable failure even when it contains text" do
      for text <- ["", "I will do that now", "Done"] do
        config = %{
          model: "test-model",
          command_runner:
            fake_runner(fn _args, _opts, output_path ->
              File.write!(
                output_path,
                Jason.encode!(%{stop_reason: "tool_use", text: text, tool_calls: []})
              )

              ""
            end)
        }

        assert {:error, %Error{kind: :malformed_reply} = error} =
                 Codex.complete([Message.user("Work")], [], config)

        assert Error.retryable?(error)

        assert {:error, %Error{kind: :malformed_reply}} =
                 Codex.stream([Message.user("Work")], [], config, fn chunk ->
                   send(self(), {:unexpected_chunk, chunk})
                   :ok
                 end)

        refute_received {:unexpected_chunk, _}
      end
    end

    test "non-map tool_calls entry returns non-retryable :protocol_error instead of raising" do
      for bad_entry <- ["bad", nil, 123] do
        config = %{
          model: "test-model",
          command_runner:
            fake_runner(fn _args, _opts, output_path ->
              File.write!(
                output_path,
                Jason.encode!(%{stop_reason: "tool_use", text: "", tool_calls: [bad_entry]})
              )

              ""
            end)
        }

        assert {:error, %Error{kind: :protocol_error, message: msg} = error} =
                 Codex.complete([Message.user("Work")], [], config)

        assert msg =~ "invalid Codex tool call entry"
        refute Error.retryable?(error)
      end
    end

    test "returns an end_turn assistant message from Codex JSON output" do
      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(
              output_path,
              ~s({"stop_reason":"end_turn","text":"All done","tool_calls":[]})
            )

            "codex\n{\"stop_reason\":\"end_turn\"}\n"
          end)
      }

      assert {:ok, result} = Codex.complete([Message.user("Hi")], [], config)
      assert result.stop_reason == :end_turn
      assert result.messages == [Message.assistant("All done")]
      assert result.usage == %{input_tokens: 0, output_tokens: 0}
      assert result.response_metadata.backend == "codex_exec"
      assert result.response_metadata.model == "gpt-5.4"
      assert result.response_metadata.command_status == 0
    end

    test "returns tool_use blocks when Codex requests tools" do
      tool_defs = [
        %{
          name: "search_examples",
          description: "Find similar inbox examples",
          input_schema: %{type: "object", properties: %{query: %{type: "string"}}}
        }
      ]

      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            payload = %{
              stop_reason: "tool_use",
              text: "",
              tool_calls: [
                %{
                  call_id: "call_1",
                  name: "search_examples",
                  arguments_json: ~s({"query":"waiting on vendor","limit":2})
                }
              ]
            }

            File.write!(output_path, Jason.encode!(payload))
            "codex\n#{Jason.encode!(payload)}\n"
          end)
      }

      assert {:ok, result} =
               Codex.complete([Message.user("Help me triage this")], tool_defs, config)

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

    test "builds a structured prompt that includes system prompt and tool definitions" do
      parent = self()

      config = %{
        model: "gpt-5.4",
        system_prompt: "You are an inbox triage harness.",
        command_runner:
          fake_runner(fn args, _opts, output_path ->
            send(parent, {:codex_args, args})
            File.write!(output_path, ~s({"stop_reason":"end_turn","text":"OK","tool_calls":[]}))
            "codex\n{\"stop_reason\":\"end_turn\"}\n"
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

      assert {:ok, _result} = Codex.complete(messages, tool_defs, config)

      assert_receive {:codex_args, args}
      prompt = List.last(args)

      assert prompt =~ "You are acting as the model backend for Alloy"
      assert prompt =~ "You are an inbox triage harness."
      assert prompt =~ "\"name\":\"search_examples\""
      assert prompt =~ "\"tool_result\""
      assert prompt =~ "\"Found two examples\""
    end

    test "returns a helpful error when Codex output violates the contract" do
      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(
              output_path,
              ~s({"stop_reason":"end_turn","text":"oops","tool_calls":[{"call_id":"call_1","name":"bad","arguments":{}}]})
            )

            "codex\n{\"stop_reason\":\"end_turn\"}\n"
          end)
      }

      assert {:error, reason} = Codex.complete([Message.user("Hi")], [], config)
      assert Exception.message(reason) =~ "tool_calls"
    end

    test "returns a helpful error when arguments_json is not valid JSON" do
      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            payload = %{
              stop_reason: "tool_use",
              text: "",
              tool_calls: [
                %{call_id: "call_1", name: "search_examples", arguments_json: "{not json}"}
              ]
            }

            File.write!(output_path, Jason.encode!(payload))
            "codex\n#{Jason.encode!(payload)}\n"
          end)
      }

      assert {:error, reason} = Codex.complete([Message.user("Hi")], [], config)
      assert Exception.message(reason) =~ "arguments_json"
    end

    test "accepts a parsed payload even if codex exits non-zero" do
      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(
              output_path,
              ~s({"stop_reason":"end_turn","text":"Recovered","tool_calls":[]})
            )

            {"codex noise on stderr", 1}
          end)
      }

      assert {:ok, result} = Codex.complete([Message.user("Hi")], [], config)
      assert result.messages == [Message.assistant("Recovered")]
      assert result.response_metadata.command_status == 1
    end

    @tag :tmp_dir
    test "passes the prompt via stdin for the real shell-backed runner", %{tmp_dir: dir} do
      script =
        script!(dir, """
        set -eu
        output=""
        last=""

        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then
            shift
            output="$1"
          else
            last="$1"
          fi

          shift
        done

        if [ "$last" != "-" ]; then
          echo "expected stdin prompt marker" >&2
          exit 41
        fi

        case "$(cat)" in
          *"Need a decision"*) ;;
          *)
            echo "missing prompt on stdin" >&2
            exit 42
            ;;
        esac

        printf '%s' '{"stop_reason":"end_turn","text":"stdin ok","tool_calls":[]}' > "$output"
        """)

      config = %{model: "gpt-5.4", codex_bin: script, codex_home: dir}

      assert {:ok, result} = Codex.complete([Message.user("Need a decision")], [], config)
      assert result.messages == [Message.assistant("stdin ok")]
    end

    @tag :tmp_dir
    test "collects output even when the process exits before os_pid can be read", %{
      tmp_dir: dir
    } do
      # Regression: Port.info(port, :os_pid) returns nil when the spawned
      # process has already exited. The output and exit_status messages are
      # still in the mailbox, so a fast-exiting codex must succeed, not
      # error with "port closed before os_pid was available". The race is
      # timing-dependent; the instant-exit script plus repetition makes it
      # likely under the old code and proves the nil branch under the new.
      config = %{model: "gpt-5.4", codex_bin: fake_codex!(dir, ""), codex_home: dir}

      for _run <- 1..20 do
        assert {:ok, result} = Codex.complete([Message.user("Hi")], [], config)
        assert result.messages == [Message.assistant("fake ok")]
      end
    end

    @tag :tmp_dir
    test "returns a timeout error instead of hanging when the real shell-backed run exceeds timeout_ms",
         %{tmp_dir: dir} do
      config = %{model: "gpt-5.4", codex_bin: slow_codex!(dir), codex_home: dir, timeout_ms: 200}

      # If the Port-based timeout path is broken, this call hangs for 30s
      # and ExUnit's own timeout would catch it — the assertion below
      # verifies the graceful error path fires instead.
      started_at = System.monotonic_time(:millisecond)
      result = Codex.complete([Message.user("hang")], [], config)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert {:error, %Error{kind: :timeout} = error} = result
      assert Exception.message(error) == "codex exec timed out after 200ms"
      # Generous slack for TERM/KILL grace window and CI noise.
      assert elapsed < 5_000,
             "expected timeout to fire within ~200ms + grace, took #{elapsed}ms"
    end

    @tag :tmp_dir
    test "progress output cannot extend the real shell-backed run's deadline", %{tmp_dir: dir} do
      script =
        script!(dir, """
        cat > /dev/null
        tick=0
        while [ "$tick" -lt 160 ]; do
          printf '%s\\n' '{"event":"progress"}'
          tick=$((tick + 1))
          sleep 0.05
        done
        """)

      config = %{
        model: "gpt-5.4",
        codex_bin: script,
        codex_home: dir,
        timeout_ms: 30_000,
        receive_timeout: 1_000
      }

      started_at = System.monotonic_time(:millisecond)
      result = Codex.complete([Message.user("progress")], [], config)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert {:error, %Error{kind: :timeout} = error} = result
      assert Exception.message(error) == "codex exec timed out after 1000ms"
      # The script prints for 8s; finishing well before that means the 1s
      # deadline held. The slack absorbs a loaded machine.
      assert elapsed < 5_000, "progress reset the turn deadline: #{elapsed}ms"
    end

    @tag :tmp_dir
    test "receive_timeout caps a larger timeout_ms for the real shell-backed run", %{
      tmp_dir: dir
    } do
      config = %{
        model: "gpt-5.4",
        codex_bin: slow_codex!(dir),
        codex_home: dir,
        timeout_ms: 30_000,
        receive_timeout: 150
      }

      started_at = System.monotonic_time(:millisecond)
      result = Codex.complete([Message.user("deadline")], [], config)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert {:error, %Error{kind: :timeout} = error} = result
      assert Exception.message(error) == "codex exec timed out after 150ms"

      assert elapsed < 5_000,
             "expected receive_timeout to cap the port timeout, took #{elapsed}ms"
    end

    @tag :tmp_dir
    test "a missing :workdir is a clear error result", %{tmp_dir: dir} do
      config = %{
        model: "gpt-5.4",
        codex_bin: exiting_codex!(dir),
        codex_home: dir,
        workdir: Path.join(dir, "does-not-exist")
      }

      assert {:error, %Alloy.Provider.Error{message: message}} =
               Codex.complete([Message.user("Hi")], [], config)

      assert message =~ "does-not-exist"
    end

    @tag :tmp_dir
    test "an explicit nil :timeout_ms falls back to the default", %{tmp_dir: dir} do
      config = %{
        model: "gpt-5.4",
        codex_bin: exiting_codex!(dir),
        codex_home: dir,
        timeout_ms: nil
      }

      # Without the fallback this raised Enum.EmptyError in the caller.
      assert {:error, %Alloy.Provider.Error{}} = Codex.complete([Message.user("Hi")], [], config)
    end

    # Alloy.Provider.Retry injects the turn deadline into :req_options (the
    # shape HTTP providers hand to Req), not as a top-level key.
    @tag :tmp_dir
    test "the turn deadline injected into :req_options caps the port timeout", %{tmp_dir: dir} do
      config = %{
        model: "gpt-5.4",
        codex_bin: slow_codex!(dir),
        codex_home: dir,
        timeout_ms: 30_000,
        req_options: [receive_timeout: 150]
      }

      started_at = System.monotonic_time(:millisecond)
      result = Codex.complete([Message.user("deadline")], [], config)
      elapsed = System.monotonic_time(:millisecond) - started_at

      assert {:error, %Error{kind: :timeout} = error} = result
      assert Exception.message(error) == "codex exec timed out after 150ms"
      assert elapsed < 5_000, "turn deadline was not applied, took #{elapsed}ms"
    end
  end

  describe "CODEX_HOME and user config" do
    test "runs against the inherited CODEX_HOME and ignores user config and rules by default" do
      parent = self()

      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn args, opts, output_path ->
            send(parent, {:codex_call, args, opts})
            File.write!(output_path, ~s({"stop_reason":"end_turn","text":"OK","tool_calls":[]}))
            ""
          end)
      }

      assert {:ok, _result} = Codex.complete([Message.user("Hi")], [], config)
      assert_receive {:codex_call, args, opts}

      assert "--ignore-user-config" in args
      assert "--ignore-rules" in args
      refute "--profile" in args
      refute List.keymember?(opts[:env], "CODEX_HOME", 0)
    end

    test ":codex_home is passed to codex as CODEX_HOME" do
      parent = self()

      config = %{
        model: "gpt-5.4",
        codex_home: "/srv/codex-home",
        command_runner:
          fake_runner(fn _args, opts, output_path ->
            send(parent, {:codex_env, opts[:env]})
            File.write!(output_path, ~s({"stop_reason":"end_turn","text":"OK","tool_calls":[]}))
            ""
          end)
      }

      assert {:ok, _result} = Codex.complete([Message.user("Hi")], [], config)
      assert_receive {:codex_env, env}
      assert {"CODEX_HOME", "/srv/codex-home"} in env
    end

    # Profiles live in $CODEX_HOME/<name>.config.toml and layer on the user
    # config, and --ignore-user-config drops both, so a profile opts back in.
    test ":profile selects the profile and loads the user config" do
      parent = self()

      config = %{
        model: "gpt-5.4",
        profile: "work",
        command_runner:
          fake_runner(fn args, _opts, output_path ->
            send(parent, {:codex_args, args})
            File.write!(output_path, ~s({"stop_reason":"end_turn","text":"OK","tool_calls":[]}))
            ""
          end)
      }

      assert {:ok, _result} = Codex.complete([Message.user("Hi")], [], config)
      assert_receive {:codex_args, args}

      assert ["--profile", "work"] ==
               args |> Enum.drop_while(&(&1 != "--profile")) |> Enum.take(2)

      refute "--ignore-user-config" in args
    end

    test ":config_overrides become -c flags" do
      parent = self()

      config = %{
        model: "gpt-5.4",
        config_overrides: [
          ~s(cli_auth_credentials_store="keyring"),
          ~s(model_reasoning_effort="high")
        ],
        command_runner:
          fake_runner(fn args, _opts, output_path ->
            send(parent, {:codex_args, args})
            File.write!(output_path, ~s({"stop_reason":"end_turn","text":"OK","tool_calls":[]}))
            ""
          end)
      }

      assert {:ok, _result} = Codex.complete([Message.user("Hi")], [], config)
      assert_receive {:codex_args, args}

      assert args
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.filter(&match?(["-c", _], &1))
             |> Enum.map(&List.last/1) == [
               ~s(cli_auth_credentials_store="keyring"),
               ~s(model_reasoning_effort="high")
             ]
    end

    @tag :tmp_dir
    test "tokens codex refreshes are kept in the codex_home, not discarded", %{tmp_dir: dir} do
      auth_path = Path.join(dir, "auth.json")
      File.write!(auth_path, ~s({"tokens":"original"}))

      script =
        fake_codex!(dir, """
        printf '%s' '{"tokens":"refreshed"}' > "$CODEX_HOME/auth.json"
        """)

      config = %{model: "gpt-5.4", codex_bin: script, codex_home: dir}

      assert {:ok, _result} = Codex.complete([Message.user("Hi")], [], config)
      assert File.read!(auth_path) == ~s({"tokens":"refreshed"})
    end

    # Keyring credential storage leaves no auth.json in CODEX_HOME.
    @tag :tmp_dir
    test "a CODEX_HOME without auth.json still runs", %{tmp_dir: dir} do
      script = fake_codex!(dir, "")
      config = %{model: "gpt-5.4", codex_bin: script, codex_home: dir}

      assert {:ok, result} = Codex.complete([Message.user("Hi")], [], config)
      assert result.messages == [Message.assistant("fake ok")]
    end

    # Ignoring it would run Codex as whichever account ~/.codex holds.
    test "the removed :auth_path raises instead of being silently ignored" do
      config = %{model: "gpt-5.4", auth_path: "/tmp/auth.json"}

      assert_raise ArgumentError, ~r/:auth_path was removed/, fn ->
        Codex.complete([Message.user("Hi")], [], config)
      end
    end
  end

  describe "usage and output streams" do
    # Recorded from codex-cli 0.160.0 `exec --json` against a stub Responses
    # endpoint; input_tokens includes cached_input_tokens.
    @completed_events """
    {"type":"thread.started","thread_id":"01a11dff-5e81-7913-b098-adc2ffe98ea5"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"{}"}}
    {"type":"turn.completed","usage":{"input_tokens":1234,"cached_input_tokens":1000,"cache_write_input_tokens":0,"output_tokens":56,"reasoning_output_tokens":7}}
    """

    @failed_events """
    {"type":"thread.started","thread_id":"01a11dfc-fc75-77f2-b638-1a812de443c1"}
    {"type":"turn.started"}
    {"type":"error","message":"Reconnecting... 5/5 (unexpected status 401 Unauthorized)"}
    {"type":"turn.failed","error":{"message":"unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"}}
    """

    test "reports token usage from the turn.completed event" do
      parent = self()

      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn args, _opts, output_path ->
            send(parent, {:codex_args, args})
            File.write!(output_path, ~s({"stop_reason":"end_turn","text":"OK","tool_calls":[]}))
            @completed_events
          end)
      }

      assert {:ok, result} = Codex.complete([Message.user("Hi")], [], config)
      assert_receive {:codex_args, args}
      assert "--json" in args

      # input_tokens is uncached input (1234 - 1000 cached), as for every
      # other built-in provider.
      assert result.usage == %{
               input_tokens: 234,
               output_tokens: 56,
               cache_read_input_tokens: 1000,
               cache_creation_input_tokens: 0,
               reasoning_output_tokens: 7
             }
    end

    # The prompt holds the whole conversation; on a shared /tmp it must not
    # be readable by other users.
    test "the temp directory holding the prompt is private to the owner" do
      parent = self()

      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            %File.Stat{mode: mode} = File.stat!(Path.dirname(output_path))
            send(parent, {:dir_mode, Bitwise.band(mode, 0o777)})
            File.write!(output_path, ~s({"stop_reason":"end_turn","text":"OK","tool_calls":[]}))
            @completed_events
          end)
      }

      assert {:ok, _result} = Codex.complete([Message.user("secret")], [], config)
      assert_receive {:dir_mode, 0o700}
    end

    test "a failed turn reports the turn.failed message" do
      config = %{
        model: "gpt-5.4",
        command_runner: fake_runner(fn _args, _opts, _output_path -> {@failed_events, 1} end)
      }

      assert {:error, reason} = Codex.complete([Message.user("Hi")], [], config)

      assert "#{reason}" ==
               "codex exec failed with status 1: unexpected status 401 Unauthorized: " <>
                 "Missing bearer or basic authentication in header"
    end

    @tag :tmp_dir
    test "stderr is kept out of the parsed event stream", %{tmp_dir: dir} do
      events = String.replace(@completed_events, "'", "")

      script =
        fake_codex!(dir, """
        echo 'ERROR codex_api: failed to connect {not json' >&2
        printf '%s' '#{events}'
        """)

      config = %{model: "gpt-5.4", codex_bin: script, codex_home: dir}

      assert {:ok, result} = Codex.complete([Message.user("Hi")], [], config)
      assert result.usage.input_tokens == 234
      refute result.response_metadata.command_output =~ "failed to connect"
    end

    @tag :tmp_dir
    test "a startup failure with no events reports stderr", %{tmp_dir: dir} do
      script =
        script!(dir, """
        cat > /dev/null
        echo 'Error: failed to parse config.toml' >&2
        exit 1
        """)

      config = %{model: "gpt-5.4", codex_bin: script, codex_home: dir}

      assert {:error, reason} = Codex.complete([Message.user("Hi")], [], config)
      assert "#{reason}" == "codex exec failed with status 1: Error: failed to parse config.toml"
    end
  end

  describe "errors" do
    @tag :tmp_dir
    test "a missing codex executable is an :unknown error naming :codex_bin", %{tmp_dir: dir} do
      missing = Path.join(dir, "no-such-codex")
      config = %{model: "gpt-5.4", codex_bin: missing, codex_home: dir}

      assert {:error, %Error{kind: :unknown} = error} =
               Codex.complete([Message.user("Hi")], [], config)

      message = Exception.message(error)
      assert message =~ "could not run codex executable #{inspect(missing)}"
      assert message =~ ":codex_bin"
    end

    test "a command_runner that cannot start codex is the same error" do
      config = %{
        model: "gpt-5.4",
        command_runner: fn _cmd, _args, _opts -> raise ErlangError, original: :enoent end
      }

      assert {:error, %Error{kind: :unknown} = error} =
               Codex.complete([Message.user("Hi")], [], config)

      assert Exception.message(error) =~ "could not run codex executable \"codex\""
    end

    test "a failed run is an :unknown error with the previous message" do
      config = %{
        model: "gpt-5.4",
        command_runner: fake_runner(fn _args, _opts, _output_path -> {"boom", 2} end)
      }

      assert {:error, %Error{kind: :unknown} = error} =
               Codex.complete([Message.user("Hi")], [], config)

      assert Exception.message(error) == "codex exec failed with status 2: boom"
      assert "#{error}" == "codex exec failed with status 2: boom"
    end

    # The loop compacts the conversation and retries on :context_overflow.
    test "a context window overflow is :context_overflow" do
      failed =
        ~s({"type":"turn.failed","error":{"message":"Codex ran out of room in the model's context window. Start a new thread or clear earlier history before retrying."}})

      config = %{
        model: "gpt-5.4",
        command_runner: fake_runner(fn _args, _opts, _output_path -> {failed, 1} end)
      }

      assert {:error, %Error{kind: :context_overflow}} =
               Codex.complete([Message.user("Hi")], [], config)
    end
  end

  describe "subprocess lifecycle" do
    @tag :tmp_dir
    test "killing the caller stops codex and its children and removes its files", %{
      tmp_dir: dir
    } do
      {script, pids_path} = hanging_codex!(dir)
      tmp_parent = Path.join(dir, "runs")
      File.mkdir_p!(tmp_parent)

      config = %{
        model: "gpt-5.4",
        codex_bin: script,
        codex_home: dir,
        tmp_dir: tmp_parent,
        timeout_ms: 30_000
      }

      caller = spawn(fn -> Codex.complete([Message.user("Hi")], [], config) end)
      pids = await_pids!(pids_path)

      Process.exit(caller, :kill)

      assert eventually(fn -> Enum.all?(pids, &(not os_alive?(&1))) end),
             "codex processes #{inspect(pids)} outlived the caller"

      assert eventually(fn -> File.ls!(tmp_parent) == [] end)
    end

    @tag :tmp_dir
    test "shutting down the owning process stops codex", %{tmp_dir: dir} do
      {script, pids_path} = hanging_codex!(dir)
      config = %{model: "gpt-5.4", codex_bin: script, codex_home: dir, timeout_ms: 30_000}
      test_pid = self()

      caller =
        spawn(fn ->
          send(test_pid, {:result, Codex.complete([Message.user("Hi")], [], config)})
        end)

      pids = await_pids!(pids_path)
      [owner] = owners_started_by(caller)

      assert :ok = Task.Supervisor.terminate_child(Alloy.TaskSupervisor, owner)
      assert Enum.all?(pids, &(not os_alive?(&1)))
      assert_receive {:result, {:error, _reason}}, 10_000
    end

    @tag :tmp_dir
    test "a timeout stops codex's child processes too", %{tmp_dir: dir} do
      {script, pids_path} = hanging_codex!(dir)
      # Long enough for the shell to start and record its pids on a loaded
      # machine; the assertion is that the timeout kills them, not how fast.
      config = %{model: "gpt-5.4", codex_bin: script, codex_home: dir, timeout_ms: 2_000}

      assert {:error, _reason} = Codex.complete([Message.user("Hi")], [], config)

      pids = await_pids!(pids_path)
      assert eventually(fn -> Enum.all?(pids, &(not os_alive?(&1))) end)
    end

    @tag :tmp_dir
    test "rejects non-zero exit with last_message under persist_session: true", %{tmp_dir: dir} do
      runner = fn _bin, args, _opts ->
        idx = Enum.find_index(args, &(&1 == "--output-last-message"))

        File.write!(
          Enum.at(args, idx + 1),
          ~s({"stop_reason":"end_turn","text":"partial","tool_calls":[]})
        )

        {"failed on disk", 1}
      end

      assert {:error, %Error{message: msg}} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 workdir: dir,
                 persist_session: true,
                 command_runner: runner
               })

      assert msg =~ "status 1"
    end

    @tag :tmp_dir
    test "timeout kills TERM-resistant descendants even when leader exits on SIGTERM", %{
      tmp_dir: dir
    } do
      marker = Path.join(dir, "survivor_marker")
      script = Path.join(dir, "fake_codex.sh")

      File.write!(script, """
      #!/bin/sh
      (trap '' TERM; sleep 1; touch "#{marker}") &
      trap 'exit 0' TERM
      sleep 5
      """)

      File.chmod!(script, 0o755)

      assert {:error, %Error{kind: :timeout}} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 codex_bin: script,
                 codex_home: dir,
                 timeout_ms: 150
               })

      Process.sleep(1_300)
      refute File.exists?(marker)
    end

    @tag :tmp_dir
    test "rejects option-like codex_bin values", %{tmp_dir: dir} do
      assert {:error, %Error{message: bad_bin_msg}} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 codex_bin: "-bad-flag",
                 codex_home: dir
               })

      assert bad_bin_msg =~ "could not run codex executable"
    end

    @tag :tmp_dir
    test "temp directories use unpredictable random names, 0700 mode, and never delete pre-existing dirs on :eexist",
         %{tmp_dir: dir} do
      test_pid = self()

      runner = fn _bin, args, _opts ->
        idx = Enum.find_index(args, &(&1 == "--output-last-message"))
        last_msg_path = Enum.at(args, idx + 1)
        send(test_pid, {:codex_dir, Path.basename(Path.dirname(last_msg_path))})
        File.write!(last_msg_path, ~s({"stop_reason":"end_turn","text":"ok","tool_calls":[]}))
        {"", 0}
      end

      assert {:ok, _} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 tmp_dir: dir,
                 command_runner: runner
               })

      assert_received {:codex_dir, dir_name}
      assert dir_name =~ ~r/^alloy-codex-[A-Za-z0-9_-]{16}$/

      # Pre-existing directory survives an :eexist collision untouched.
      existing = Path.join(dir, "preexisting")
      sentinel = Path.join(existing, "keep.txt")
      File.mkdir_p!(existing)
      File.write!(sentinel, "important")

      assert {:error, %Error{kind: :unknown, message: collision_msg}} =
               CodexRunner.create_temp_dir(dir, "preexisting")

      assert collision_msg =~ "eexist"
      assert File.read!(sentinel) == "important"

      # Fresh directory is created with 0700 permissions under the default umask.
      assert {:ok, fresh} = CodexRunner.create_temp_dir(dir, "fresh-dir")
      %File.Stat{mode: mode} = File.stat!(fresh)
      assert Bitwise.band(mode, 0o777) == 0o700

      # Atomic 0700 creation also holds under a permissive umask (000).
      sh = System.find_executable("sh")
      elixir = System.find_executable("elixir")
      assert is_binary(sh), "sh executable is required for permissive-umask regression test"

      assert is_binary(elixir),
             "elixir executable is required for permissive-umask regression test"

      ebin = Mix.Project.compile_path()

      code =
        ~S'{:ok, p} = Alloy.Provider.CodexRunner.create_temp_dir(hd(System.argv()), "umask-zero"); IO.puts("DIR:" <> p)'

      {output, status} =
        System.cmd(
          sh,
          [
            "-c",
            ~S(umask 000 && exec "$1" -pa "$2" -e "$3" -- "$4"),
            "umask-test",
            elixir,
            ebin,
            code,
            dir
          ]
        )

      assert status == 0, output

      ["DIR:" <> created] =
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "DIR:"))

      %File.Stat{mode: umask_mode} = File.stat!(created)
      assert Bitwise.band(umask_mode, 0o777) == 0o700

      # Fails closed without creating an insecure directory when atomic mkdir is unavailable.
      assert {:error, %Error{kind: :unknown, message: no_mkdir_msg}} =
               CodexRunner.create_temp_dir(dir, "no-mkdir", find_mkdir: fn -> nil end)

      assert no_mkdir_msg =~ "atomic_mkdir_unavailable"
      refute File.exists?(Path.join(dir, "no-mkdir"))

      # Non-directory tmp_dir returns typed %Error{}.
      blocker = Path.join(dir, "not_a_dir")
      File.write!(blocker, "file")

      assert {:error, %Error{kind: :unknown, message: tmp_msg}} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 tmp_dir: blocker,
                 command_runner: fn _, _, _ -> {"", 0} end
               })

      assert tmp_msg =~ "failed to prepare Codex temp directory"
    end

    @tag :tmp_dir
    test "write_inputs wraps file write failures in typed Error", %{tmp_dir: dir} do
      missing_parent = Path.join(dir, "missing")

      paths = %{
        schema_path: Path.join(missing_parent, "schema.json"),
        prompt_path: Path.join(missing_parent, "prompt.txt")
      }

      assert {:error, %Error{kind: :unknown, message: msg}} =
               CodexRunner.write_inputs(paths, "{}", "hi")

      assert msg =~ "failed to write Codex input files"
    end

    @tag :tmp_dir
    test "already-expired alloy_request_deadline returns timeout without launching codex", %{
      tmp_dir: dir
    } do
      marker = Path.join(dir, "should_not_run")
      script = script!(dir, "touch \"#{marker}\"\nexit 0\n")
      past = System.monotonic_time(:millisecond) - 10

      assert {:error, %Error{kind: :timeout}} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 codex_bin: script,
                 codex_home: dir,
                 timeout_ms: 5_000,
                 alloy_request_deadline: past
               })

      refute File.exists?(marker)

      assert {:error, %Error{kind: :timeout}} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 timeout_ms: 5_000,
                 alloy_request_deadline: past,
                 command_runner: fn _, _, _ ->
                   flunk("command_runner must not run after expiry")
                 end
               })
    end

    @tag :tmp_dir
    test "alloy_request_deadline bounds the real subprocess ahead of a larger timeout_ms", %{
      tmp_dir: dir
    } do
      started = System.monotonic_time(:millisecond)

      assert {:error, %Error{kind: :timeout}} =
               Codex.complete([Message.user("hi")], [], %{
                 model: "gpt-5.4",
                 codex_bin: slow_codex!(dir),
                 codex_home: dir,
                 timeout_ms: 30_000,
                 alloy_request_deadline: started + 150
               })

      assert System.monotonic_time(:millisecond) - started < 5_000
    end
  end

  describe "stream/4" do
    @tag :tmp_dir
    test "large fragmented diagnostic lines do not enter the answer", %{tmp_dir: dir} do
      script =
        fake_codex!(dir, """
        printf '%s' '{"type":"item.completed","item":{"type":"command_execution","output":"'
        head -c 2097152 /dev/zero | tr '\\000' x
        printf '%s\\n' '"}}'
        printf '%s\\n' '#{reply_event("fake ok")}' '{"type":"turn.completed"}'
        """)

      config = %{model: "test-model", codex_bin: script, codex_home: dir}

      assert {:ok, _result} =
               Codex.stream([Message.user("hi")], [], config, fn text ->
                 send(self(), {:answer, text})
                 :ok
               end)

      assert_receive {:answer, "fake ok"}
      refute_received {:answer, _text}
    end

    @tag :tmp_dir
    test "only the final structured answer streams at turn completion", %{tmp_dir: dir} do
      script =
        fake_codex!(dir, """
        printf '%s\\n' '#{reply_event("preamble")}'
        printf '%s\\n' '#{reply_event("fake ok")}'
        printf '%s\\n' '{"type":"turn.completed"}'
        """)

      config = %{model: "test-model", codex_bin: script, codex_home: dir}

      assert {:ok, _result} =
               Codex.stream([Message.user("hi")], [], config, fn text ->
                 send(self(), {:answer, text})
                 :ok
               end)

      assert_receive {:answer, "fake ok"}
      refute_received {:answer, _text}
    end

    @tag :tmp_dir
    test "without turn completion a candidate is not streamed ahead of the final file", %{
      tmp_dir: dir
    } do
      script = fake_codex!(dir, "printf '%s\\n' '#{reply_event("preamble")}'")
      config = %{model: "test-model", codex_bin: script, codex_home: dir}

      assert {:ok, _result} =
               Codex.stream([Message.user("hi")], [], config, fn text ->
                 send(self(), {:answer, text})
                 :ok
               end)

      assert_receive {:answer, "fake ok"}
      refute_received {:answer, _text}
    end

    @tag :tmp_dir
    test "the loop never retries a timeout after an answer was emitted", %{tmp_dir: dir} do
      invocations = Path.join(dir, "invocations")

      script =
        fake_codex!(dir, """
        printf 'x' >> "#{invocations}"
        printf '%s\\n' '#{reply_event("fake ok")}'
        printf '%s\\n' '{"type":"turn.completed"}'
        sleep 30
        """)

      parent = self()

      result =
        Alloy.stream(
          "hi",
          fn text ->
            send(parent, {:answer, text})
            :ok
          end,
          provider:
            {Codex, %{model: "test-model", codex_bin: script, codex_home: dir, timeout_ms: 5_000}},
          max_retries: 2,
          retry_backoff_ms: 1
        )

      assert {:error, _reason} = result
      assert_receive {:answer, "fake ok"}
      refute_received {:answer, _text}
      assert File.read!(invocations) == "x"
    end

    defp reply_event(text) do
      payload = Jason.encode!(%{stop_reason: "end_turn", text: text, tool_calls: []})
      Jason.encode!(%{type: "item.completed", item: %{type: "agent_message", text: payload}})
    end

    @tag :tmp_dir
    test "streams only a validated answer before exit, in the caller, without replay", %{
      tmp_dir: dir
    } do
      acknowledged = Path.join(dir, "acknowledged")
      event = reply_event("fake ok")
      split_at = div(byte_size(event), 2)
      {first, last} = String.split_at(event, split_at)

      script =
        fake_codex!(dir, """
        printf '%s\\n' '{"type":"item.started","item":{"type":"command_execution","command":"secret diagnostic"}}'
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Working..."}}'
        printf '%s' '#{first}'
        sleep 0.02
        printf '%s\\n' '#{last}'
        printf '%s\\n' '{"type":"turn.completed"}'
        while [ ! -f "#{acknowledged}" ]; do sleep 0.01; done
        """)

      caller = self()
      config = %{model: "test-model", codex_bin: script, codex_home: dir, timeout_ms: 5_000}

      assert {:ok, result} =
               Codex.stream([Message.user("hi")], [], config, fn text ->
                 assert self() == caller
                 send(caller, {:answer, text})
                 File.write!(acknowledged, "ok")
                 :ok
               end)

      assert_receive {:answer, "fake ok"}
      refute_received {:answer, _text}
      assert result.messages == [Message.assistant("fake ok")]
      assert result.response_metadata.command_output =~ "secret diagnostic"
    end

    @tag :tmp_dir
    test "a different final reply is an error rather than silently changing streamed text", %{
      tmp_dir: dir
    } do
      script =
        fake_codex!(
          dir,
          "printf '%s\\n' '#{reply_event("different")}' '{\"type\":\"turn.completed\"}'"
        )

      config = %{model: "test-model", codex_bin: script, codex_home: dir}

      assert {:error, %Error{kind: :malformed_reply}} =
               Codex.stream([Message.user("hi")], [], config, fn text ->
                 send(self(), {:answer, text})
                 :ok
               end)

      assert_receive {:answer, "different"}
      refute_received {:answer, _text}
    end

    @tag :tmp_dir
    test "callback cancellation stops children and removes temporary files", %{tmp_dir: dir} do
      pids_path = Path.join(dir, "pids")
      runs = Path.join(dir, "runs")
      File.mkdir_p!(runs)

      script =
        fake_codex!(dir, """
        sleep 30 &
        echo "$$ $!" > "#{pids_path}"
        printf '%s\\n' '#{reply_event("fake ok")}'
        printf '%s\\n' '{"type":"turn.completed"}'
        wait
        """)

      config = %{model: "test-model", codex_bin: script, codex_home: dir, tmp_dir: runs}

      assert catch_throw(
               Codex.stream([Message.user("hi")], [], config, fn _text -> throw(:cancel) end)
             ) == :cancel

      pids = await_pids!(pids_path)
      assert eventually(fn -> Enum.all?(pids, &(not os_alive?(&1))) end)
      assert File.ls!(runs) == []
    end

    @tag :tmp_dir
    test "mid-stream reply_fn exception stops codex children and removes temporary files", %{
      tmp_dir: dir
    } do
      pids_path = Path.join(dir, "pids")
      runs = Path.join(dir, "runs")
      File.mkdir_p!(runs)

      script =
        fake_codex!(dir, """
        sleep 30 &
        echo "$$ $!" > "#{pids_path}"
        printf '%s\\n' '#{reply_event("boom")}'
        wait
        """)

      config = %{
        model: "test-model",
        codex_bin: script,
        codex_home: dir,
        tmp_dir: runs,
        alloy_on_chunk: fn _ -> :ok end
      }

      build_args = fn paths ->
        ["exec", "--output-last-message", paths.last_message_path]
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %Error{kind: :unknown, message: msg}} =
                   CodexRunner.execute(
                     "hi",
                     dir,
                     build_args,
                     "{}",
                     config,
                     fn _text -> raise "reply parser boom" end
                   )

          assert msg == "codex exec failed: RuntimeError"
        end)

      refute log =~ "reply parser boom"
      refute log =~ "CodexRunner"
      pids = await_pids!(pids_path)
      assert eventually(fn -> Enum.all?(pids, &(not os_alive?(&1))) end)
      assert File.ls!(runs) == []
    end

    @tag :tmp_dir
    test "supervisor shutdown returns :shutdown (fresh and resumed plans), kills the codex process group, and removes the temp dir",
         %{tmp_dir: dir} do
      {script, pids_path} = hanging_codex!(dir)
      runs = Path.join(dir, "runs")
      File.mkdir_p!(runs)

      config = %{
        model: "gpt-5.4",
        codex_bin: script,
        codex_home: dir,
        tmp_dir: runs,
        timeout_ms: 30_000
      }

      caller_task =
        Task.async(fn ->
          Codex.complete([Message.user("Hi")], [], config)
        end)

      pids = await_pids!(pids_path)
      assert eventually(fn -> owners_started_by(caller_task.pid) != [] end)
      [owner] = owners_started_by(caller_task.pid)
      Process.exit(owner, :shutdown)

      assert {:error, %Error{kind: :shutdown, message: "codex exec interrupted by shutdown"}} =
               Task.await(caller_task, 5_000)

      assert eventually(fn -> Enum.all?(pids, &(not os_alive?(&1))) end)
      assert File.ls!(runs) == []

      # Persisted resume plan interrupted by shutdown preserves kind: :shutdown
      # (so Retry skips fallbacks) while noting :session_generation uncertainty.
      resume_pids_path = Path.join(dir, "resume_pids")
      marker_path = Path.join(dir, "turn1_done")

      two_turn_script =
        fake_codex!(dir, """
        if [ ! -f "#{marker_path}" ]; then
          touch "#{marker_path}"
          printf '%s\\n' '{"type":"thread.started","thread_id":"thread_shutdown_1"}'
        else
          sleep 30 &
          echo "$$ $!" > "#{resume_pids_path}.tmp" && mv "#{resume_pids_path}.tmp" "#{resume_pids_path}"
          wait
        fi
        """)

      resume_base = %{
        model: "gpt-5.4",
        codex_bin: two_turn_script,
        codex_home: dir,
        workdir: dir,
        tmp_dir: runs,
        persist_session: true,
        timeout_ms: 30_000
      }

      turn1_msgs = [Message.user("turn 1")]
      assert {:ok, turn1_res} = Codex.complete(turn1_msgs, [], resume_base)
      assert turn1_res.provider_state["codex_session"]["id"] == "thread_shutdown_1"

      resume_config = Map.put(resume_base, :provider_state, turn1_res.provider_state)

      resume_task =
        Task.async(fn ->
          Codex.complete(
            turn1_msgs ++ turn1_res.messages ++ [Message.user("turn 2")],
            [],
            resume_config
          )
        end)

      resume_pids = await_pids!(resume_pids_path)
      assert eventually(fn -> owners_started_by(resume_task.pid) != [] end)
      [resume_owner] = owners_started_by(resume_task.pid)
      Process.exit(resume_owner, :shutdown)

      assert {:error, %Error{kind: :shutdown, message: resume_msg}} =
               Task.await(resume_task, 5_000)

      assert resume_msg =~ "session_generation"
      assert eventually(fn -> Enum.all?(resume_pids, &(not os_alive?(&1))) end)
      assert File.ls!(runs) == []
    end

    @tag :tmp_dir
    test "external non-shutdown owner exit returns sanitized :unknown error and cleans up", %{
      tmp_dir: dir
    } do
      runs = Path.join(dir, "runs")
      File.mkdir_p!(runs)
      {script, pids_path} = hanging_codex!(dir)

      task =
        Task.async(fn ->
          Codex.complete([Message.user("hi")], [], %{
            model: "gpt-5.4",
            codex_bin: script,
            codex_home: dir,
            tmp_dir: runs,
            timeout_ms: 30_000
          })
        end)

      pids = await_pids!(pids_path)
      assert eventually(fn -> owners_started_by(task.pid) != [] end)
      [owner] = owners_started_by(task.pid)
      Process.exit(owner, {:custom_crash, "secret-token"})

      assert {:error, %Error{kind: :unknown, message: msg}} = Task.await(task, 5_000)
      assert msg =~ ":custom_crash"
      refute msg =~ "secret-token"
      assert eventually(fn -> Enum.all?(pids, &(not os_alive?(&1))) end)
      assert File.ls!(runs) == []
    end

    test "replays the final assistant text through the callback" do
      parent = self()

      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(
              output_path,
              ~s({"stop_reason":"end_turn","text":"Chunk me","tool_calls":[]})
            )

            "codex\n{\"stop_reason\":\"end_turn\"}\n"
          end)
      }

      assert {:ok, result} =
               Codex.stream([Message.user("Hi")], [], config, fn chunk ->
                 send(parent, {:chunk, chunk})
                 :ok
               end)

      assert_receive {:chunk, "Chunk me"}
      assert result.messages == [Message.assistant("Chunk me")]
    end
  end

  defp fake_runner(fun) do
    fn _cmd, args, opts ->
      output_path = output_path!(args)

      case fun.(args, opts, output_path) do
        {output, status} when is_binary(output) and is_integer(status) -> {output, status}
        output when is_binary(output) -> {output, 0}
      end
    end
  end

  defp output_path!(args) do
    index = Enum.find_index(args, &(&1 == "--output-last-message"))
    Enum.at(args, index + 1)
  end

  # A stand-in `codex` executable for the real port path.
  defp script!(dir, body) do
    path = Path.join(dir, "fake-codex")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # Runs `body`, then writes a fixed end_turn payload to the
  # --output-last-message file.
  defp fake_codex!(dir, body) do
    script!(dir, """
    output=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--output-last-message" ]; then
        shift
        output="$1"
      fi
      shift
    done
    cat > /dev/null
    #{body}
    printf '%s' '{"stop_reason":"end_turn","text":"fake ok","tool_calls":[]}' > "$output"
    """)
  end

  # Drains stdin so the shell redirect completes, then hangs.
  defp exiting_codex!(dir) do
    path = Path.join(dir, "exiting-codex.sh")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp slow_codex!(dir), do: script!(dir, "cat > /dev/null\nsleep 30\n")

  # A codex that starts a child process, records both OS pids, and hangs.
  defp hanging_codex!(dir) do
    pids_path = Path.join(dir, "pids")

    script =
      fake_codex!(dir, """
      sleep 30 &
      echo "$$ $!" > "#{pids_path}.tmp" && mv "#{pids_path}.tmp" "#{pids_path}"
      wait
      """)

    {script, pids_path}
  end

  defp await_pids!(path) do
    assert eventually(fn -> File.exists?(path) end), "fake codex never started"
    path |> File.read!() |> String.split()
  end

  defp owners_started_by(caller) do
    for pid <- Task.Supervisor.children(Alloy.TaskSupervisor),
        {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
        caller in Keyword.get(dictionary, :"$callers", []),
        do: pid
  end

  # `kill -0` probes a pid without signalling it; it needs no environment.
  defp os_alive?(os_pid) do
    no_env = Enum.map(System.get_env(), fn {name, _value} -> {name, nil} end)

    {_output, status} =
      System.cmd("/bin/sh", ["-c", ~S(kill -0 "$1"), "probe", os_pid],
        env: no_env,
        stderr_to_stdout: true
      )

    status == 0
  end

  defp eventually(fun, attempts \\ 50) do
    case fun.() do
      true ->
        true

      false when attempts == 0 ->
        false

      false ->
        Process.sleep(100)
        eventually(fun, attempts - 1)
    end
  end
end
