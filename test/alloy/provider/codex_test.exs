defmodule Alloy.Provider.CodexTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.{Codex, Error}

  describe "complete/3" do
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

    test "a raw newline inside an arguments_json string is read as an escaped one" do
      script = "local a = 1\nreturn a"
      raw = ~s({"script":") <> script <> ~s("})

      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            payload = %{
              stop_reason: "tool_use",
              text: "",
              tool_calls: [%{call_id: "call_1", name: "run_script", arguments_json: raw}]
            }

            File.write!(output_path, Jason.encode!(payload))
            "codex\n#{Jason.encode!(payload)}\n"
          end)
      }

      assert {:ok, %{messages: [%Message{content: blocks}]}} =
               Codex.complete([Message.user("Hi")], [], config)

      assert [%{type: "tool_use", input: %{"script" => ^script}}] =
               Enum.filter(blocks, &match?(%{type: "tool_use"}, &1))
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
    test "tokens codex refreshes are kept in the auth_path home, not discarded", %{tmp_dir: dir} do
      auth_path = Path.join(dir, "auth.json")
      File.write!(auth_path, ~s({"tokens":"original"}))

      script =
        fake_codex!(dir, """
        printf '%s' '{"tokens":"refreshed"}' > "$CODEX_HOME/auth.json"
        """)

      config = %{model: "gpt-5.4", codex_bin: script, auth_path: auth_path}

      assert {:ok, _result} = Codex.complete([Message.user("Hi")], [], config)
      assert File.read!(auth_path) == ~s({"tokens":"refreshed"})
    end

    # Keyring credential storage leaves no auth.json to copy.
    @tag :tmp_dir
    test "a CODEX_HOME without auth.json still runs", %{tmp_dir: dir} do
      script = fake_codex!(dir, "")
      config = %{model: "gpt-5.4", codex_bin: script, auth_path: Path.join(dir, "auth.json")}

      assert {:ok, result} = Codex.complete([Message.user("Hi")], [], config)
      assert result.messages == [Message.assistant("fake ok")]
    end

    # 0.12.4 copied any :auth_path file into a private CODEX_HOME; a file
    # with another name still works that way until :auth_path is removed.
    @tag :tmp_dir
    test "an :auth_path not named auth.json is copied into a private CODEX_HOME",
         %{tmp_dir: dir} do
      token = Path.join(dir, "codex-token.json")
      File.write!(token, ~s({"token":"t"}))
      parent = self()

      config = %{
        model: "gpt-5.4",
        auth_path: token,
        command_runner:
          fake_runner(fn _args, opts, output_path ->
            home = opts |> Keyword.fetch!(:env) |> List.keyfind("CODEX_HOME", 0) |> elem(1)
            send(parent, {:home, home, File.read(Path.join(home, "auth.json"))})
            File.write!(output_path, ~s({"stop_reason":"end_turn","text":"OK","tool_calls":[]}))
            ""
          end)
      }

      assert {:ok, _result} = Codex.complete([Message.user("Hi")], [], config)
      assert_receive {:home, home, {:ok, ~s({"token":"t"})}}
      refute home == dir
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
  end

  describe "session continuation" do
    @thread "01a0e329-c415-74d3-a094-f28ef64e03cc"
    @earlier [Message.user("Remember PLUM"), Message.assistant("OK")]

    test "reports the thread to resume from --json events" do
      config = %{model: "gpt-5.4", command_runner: fake_runner(json_reply("Hi back"))}
      messages = [Message.user("Hi")]

      assert {:ok, result} = Codex.complete(messages, [], config)

      assert result.usage == %{
               input_tokens: 26_486,
               output_tokens: 11,
               cache_read_input_tokens: 20_864,
               cache_creation_input_tokens: 0,
               reasoning_output_tokens: 0
             }

      prefix = messages ++ [Message.assistant("Hi back")]

      assert result.provider_state == %{
               session_id: @thread,
               sent_upto: 2,
               prefix_hash: :erlang.phash2(prefix),
               tools_hash: :erlang.phash2([]),
               system_hash: :erlang.phash2(nil)
             }
    end

    test "resumes the thread and sends only the messages it has not seen" do
      parent = self()
      messages = @earlier ++ [Message.user("What was it?")]

      config =
        resumed_config(
          fake_runner(fn args, opts, path ->
            send(parent, {:args, args})
            json_reply("PLUM").(args, opts, path)
          end)
        )

      assert {:ok, result} = Codex.complete(messages, [], config)
      assert_receive {:args, ["exec", "resume" | _] = args}

      prompt = List.last(args)
      assert Enum.at(args, -2) == @thread
      assert prompt =~ "What was it?"
      refute prompt =~ "Remember PLUM"
      assert result.provider_state.sent_upto == 4
    end

    # A fresh turn records its thread; only one that can never be resumed is
    # --ephemeral. `exec resume` has no --sandbox, so it is a -c override.
    test "fresh and resumed turns run under the same configuration" do
      parent = self()

      runner =
        fake_runner(fn args, opts, path ->
          send(parent, {:args, args})
          json_reply("PLUM").(args, opts, path)
        end)

      assert {:ok, _} = Codex.complete(@earlier, [], %{model: "gpt-5.4", command_runner: runner})
      assert_receive {:args, ["exec", "--json" | _] = fresh}

      assert {:ok, _} =
               Codex.complete(@earlier ++ [Message.user("What?")], [], resumed_config(runner))

      assert_receive {:args, ["exec", "resume" | _] = resume}

      for args <- [fresh, resume], flag <- ["--json", "--ignore-user-config", "--ignore-rules"] do
        assert flag in args, "#{flag} missing from #{inspect(args)}"
      end

      refute "--ephemeral" in fresh
      refute "--ephemeral" in resume

      assert ["--sandbox", "read-only"] ==
               fresh |> Enum.drop_while(&(&1 != "--sandbox")) |> Enum.take(2)

      refute "--sandbox" in resume
      assert ~s(sandbox_mode="read-only") in resume
    end

    test "codex runs no command of its own, fresh or resumed" do
      parent = self()

      runner =
        fake_runner(fn args, opts, path ->
          send(parent, {:args, args})
          json_reply("PLUM").(args, opts, path)
        end)

      assert {:ok, _} = Codex.complete(@earlier, [], %{model: "gpt-5.4", command_runner: runner})

      assert {:ok, _} =
               Codex.complete(@earlier ++ [Message.user("What?")], [], resumed_config(runner))

      assert_receive {:args, ["exec", "--json" | _] = fresh}
      assert_receive {:args, ["exec", "resume" | _] = resume}

      for args <- [fresh, resume], feature <- ["shell_tool", "unified_exec"] do
        assert feature in disabled(args), "codex kept #{feature} in #{inspect(args)}"
      end
    end

    # `exec resume` takes no --profile, and a copied :auth_path home is
    # deleted with the call, so neither leaves a thread to resume.
    test "a profiled turn runs --ephemeral and keeps no thread" do
      parent = self()

      runner =
        fake_runner(fn args, opts, path ->
          send(parent, {:args, args})
          json_reply("PLUM").(args, opts, path)
        end)

      config =
        runner
        |> resumed_config()
        |> Map.put(:profile, "work")

      assert {:ok, result} = Codex.complete(@earlier ++ [Message.user("What?")], [], config)
      assert_receive {:args, ["exec", "--json" | _] = args}
      assert "--ephemeral" in args
      assert List.last(args) =~ "Remember PLUM"
      refute Map.has_key?(result, :provider_state)
      assert result.response_metadata.session.reason == :ephemeral
    end

    @tag :tmp_dir
    test "a copied :auth_path home runs --ephemeral", %{tmp_dir: dir} do
      token = Path.join(dir, "codex-token.json")
      File.write!(token, ~s({"token":"t"}))
      parent = self()

      runner =
        fake_runner(fn args, opts, path ->
          send(parent, {:args, args})
          json_reply("PLUM").(args, opts, path)
        end)

      config = Map.put(resumed_config(runner), :auth_path, token)

      assert {:ok, result} = Codex.complete(@earlier ++ [Message.user("What?")], [], config)
      assert_receive {:args, ["exec", "--json" | _] = args}
      assert "--ephemeral" in args
      refute Map.has_key?(result, :provider_state)
    end

    test "a resumed turn sends the tool list only when it changed" do
      parent = self()
      messages = @earlier ++ [Message.user("What was it?")]
      tools = [%{name: "read_file", description: "Read a file", input_schema: %{type: "object"}}]

      runner =
        fake_runner(fn args, opts, path ->
          send(parent, {:prompt, List.last(args)})
          json_reply("PLUM").(args, opts, path)
        end)

      # The first turn's full prompt carried these tools, so the thread has them.
      assert {:ok, first} =
               Codex.complete([Message.user("Hi")], tools, %{
                 model: "gpt-5.4",
                 command_runner: runner
               })

      assert_receive {:prompt, _fresh}
      known = first.provider_state.tools_hash

      unchanged = resumed_config(runner, %{tools_hash: known})
      assert {:ok, _} = Codex.complete(messages, tools, unchanged)
      assert_receive {:prompt, resumed}
      refute resumed =~ "available_tools"
      assert resumed =~ "What was it?"

      changed = resumed_config(runner, %{tools_hash: :erlang.phash2([])})
      assert {:ok, _} = Codex.complete(messages, tools, changed)
      assert_receive {:prompt, resent}
      assert resent =~ "available_tools"
      assert resent =~ "read_file"
    end

    test "a resumed turn sends the system prompt only when it changed" do
      parent = self()
      messages = @earlier ++ [Message.user("What was it?")]

      runner =
        fake_runner(fn args, opts, path ->
          send(parent, {:prompt, List.last(args)})
          json_reply("PLUM").(args, opts, path)
        end)

      assert {:ok, first} =
               Codex.complete([Message.user("Hi")], [], %{
                 model: "gpt-5.4",
                 system_prompt: "Brief v1",
                 command_runner: runner
               })

      assert_receive {:prompt, _fresh}

      same =
        runner
        |> resumed_config(Map.take(first.provider_state, [:tools_hash, :system_hash]))
        |> Map.put(:system_prompt, "Brief v1")

      assert {:ok, _} = Codex.complete(messages, [], same)
      assert_receive {:prompt, resumed}
      refute resumed =~ "Brief v1"

      assert {:ok, _} = Codex.complete(messages, [], %{same | system_prompt: "Brief v2"})
      assert_receive {:prompt, resent}
      assert resent =~ "Brief v2"
    end

    test "sends the full transcript when earlier history was rewritten" do
      parent = self()
      messages = [Message.user("Compacted summary"), Message.assistant("OK"), Message.user("Go")]

      config = %{
        model: "gpt-5.4",
        provider_state: %{session_id: @thread, sent_upto: 2, prefix_hash: 0},
        command_runner:
          fake_runner(fn args, opts, path ->
            send(parent, {:args, args})
            json_reply("Going").(args, opts, path)
          end)
      }

      {result, log} = ExUnit.CaptureLog.with_log(fn -> Codex.complete(messages, [], config) end)

      assert {:ok, %{response_metadata: %{session: %{mode: :fresh, reason: :history_rewritten}}}} =
               result

      assert log =~ "starting a new thread"
      assert_receive {:args, ["exec", "--json" | _] = args}
      assert List.last(args) =~ "Compacted summary"
    end

    test "falls back to the full transcript when the thread cannot be resumed" do
      parent = self()
      messages = @earlier ++ [Message.user("What was it?")]

      config =
        resumed_config(
          fake_runner(fn args, opts, path ->
            send(parent, {:args, args})

            case args do
              ["exec", "resume" | _] -> {"Error: thread not found", 1}
              _ -> json_reply("PLUM").(args, opts, path)
            end
          end)
        )

      {result, log} = ExUnit.CaptureLog.with_log(fn -> Codex.complete(messages, [], config) end)

      assert {:ok, %{messages: [%Message{content: "PLUM"}]} = completion} = result
      assert completion.response_metadata.session.reason == :resume_failed
      assert log =~ "could not resume thread #{@thread}"
      assert_receive {:args, ["exec", "resume" | _]}
      assert_receive {:args, ["exec", "--json" | _] = fresh}
      assert List.last(fresh) =~ "Remember PLUM"
    end

    test "says whether a turn resumed, and which thread" do
      config = resumed_config(fake_runner(json_reply("PLUM")))

      assert {:ok, resumed} = Codex.complete(@earlier ++ [Message.user("What?")], [], config)

      assert resumed.response_metadata.session ==
               %{mode: :resumed, reason: nil, thread_id: @thread}

      first = %{model: "gpt-5.4", command_runner: fake_runner(json_reply("Hi"))}

      assert {:ok, %{response_metadata: %{session: %{mode: :fresh, reason: :no_session}}}} =
               Codex.complete([Message.user("Hi")], [], first)
    end

    defp resumed_config(runner, state \\ %{}) do
      %{
        model: "gpt-5.4",
        command_runner: runner,
        provider_state:
          Map.merge(
            %{session_id: @thread, sent_upto: 2, prefix_hash: :erlang.phash2(@earlier)},
            state
          )
      }
    end

    defp json_reply(text) do
      fn _args, _opts, output_path ->
        File.write!(
          output_path,
          Jason.encode!(%{stop_reason: "end_turn", text: text, tool_calls: []})
        )

        """
        {"type":"thread.started","thread_id":"#{@thread}"}
        {"type":"turn.started"}
        {"type":"turn.completed","usage":{"input_tokens":47350,"cached_input_tokens":20864,"cache_write_input_tokens":0,"output_tokens":11}}
        """
      end
    end
  end

  describe "stream/4" do
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

    test "hands on each message and command as Codex writes it, and does not replay the reply" do
      parent = self()
      reply = Jason.encode!(%{stop_reason: "end_turn", text: "Rivers flow.", tool_calls: []})

      config = %{
        model: "gpt-5.4",
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(output_path, reply)

            Enum.map_join(
              [
                %{type: "thread.started", thread_id: "t-1"},
                %{
                  type: "item.completed",
                  item: %{type: "agent_message", text: "I'll look first.\n"}
                },
                %{type: "item.started", item: %{type: "command_execution", command: "ls"}},
                %{type: "item.completed", item: %{type: "agent_message", text: reply}},
                %{type: "turn.completed", usage: %{input_tokens: 10, output_tokens: 2}}
              ],
              "\n",
              &Jason.encode!/1
            )
          end)
      }

      assert {:ok, result} =
               Codex.stream([Message.user("Rivers?")], [], config, fn chunk ->
                 send(parent, {:chunk, chunk})
                 :ok
               end)

      assert_receive {:chunk, "I'll look first.\n"}
      assert_receive {:chunk, "\n$ ls\n"}
      assert_receive {:chunk, "Rivers flow."}
      refute_receive {:chunk, "Rivers flow."}
      assert result.messages == [Message.assistant("Rivers flow.")]
    end

    test "tells a streaming caller when a turn starts a new thread" do
      parent = self()
      reply = Jason.encode!(%{stop_reason: "end_turn", text: "Going", tool_calls: []})

      config = %{
        model: "gpt-5.4",
        provider_state: %{session_id: "t-1", sent_upto: 2, prefix_hash: 0},
        command_runner:
          fake_runner(fn _args, _opts, output_path ->
            File.write!(output_path, reply)
            ~s({"type":"thread.started","thread_id":"t-2"})
          end)
      }

      messages = [Message.user("Compacted summary"), Message.assistant("OK"), Message.user("Go")]

      ExUnit.CaptureLog.with_log(fn ->
        Codex.stream(messages, [], config, fn chunk ->
          send(parent, {:chunk, chunk})
          :ok
        end)
      end)

      assert_receive {:chunk, notice}
      assert notice =~ "new Codex thread"
      assert notice =~ "compaction"
    end

    # The fake codex prints its first message and then waits for a file that
    # only the callback creates. Chunks handed on at exit would never create
    # it, and the turn would time out instead of finishing.
    @tag :tmp_dir
    test "hands on a message while codex is still running, in the calling process", %{
      tmp_dir: dir
    } do
      go_path = Path.join(dir, "go")

      script =
        script!(dir, """
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then shift; output="$1"; fi
          shift
        done
        cat > /dev/null
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"working on it"}}'
        while [ ! -f "#{go_path}" ]; do sleep 0.05; done
        printf '%s' '{"stop_reason":"end_turn","text":"done","tool_calls":[]}' > "$output"
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"stop_reason\\":\\"end_turn\\",\\"text\\":\\"done\\",\\"tool_calls\\":[]}"}}'
        """)

      config = %{model: "gpt-5.4", codex_bin: script, codex_home: dir, timeout_ms: 10_000}
      parent = self()

      assert {:ok, result} =
               Codex.stream([Message.user("Go")], [], config, fn chunk ->
                 if chunk =~ "working on it", do: File.write!(go_path, "")
                 send(parent, {:chunk, self(), chunk})
                 :ok
               end)

      assert_receive {:chunk, ^parent, "working on it\n"}
      assert_receive {:chunk, ^parent, "done"}
      assert result.messages == [Message.assistant("done")]
    end

    @tag :tmp_dir
    test "a callback that raises stops codex", %{tmp_dir: dir} do
      pids_path = Path.join(dir, "pids")

      script =
        script!(dir, """
        cat > /dev/null
        sleep 30 &
        echo "$$ $!" > "#{pids_path}.tmp" && mv "#{pids_path}.tmp" "#{pids_path}"
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}'
        wait
        """)

      config = %{model: "gpt-5.4", codex_bin: script, codex_home: dir, timeout_ms: 30_000}

      assert_raise RuntimeError, "callback failed", fn ->
        Codex.stream([Message.user("Go")], [], config, fn _chunk -> raise "callback failed" end)
      end

      pids = await_pids!(pids_path)
      assert eventually(fn -> Enum.all?(pids, &(not os_alive?(&1))) end)
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

  defp disabled(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["--disable", feature] -> [feature]
      _other -> []
    end)
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
