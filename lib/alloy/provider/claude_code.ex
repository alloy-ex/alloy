defmodule Alloy.Provider.ClaudeCode do
  @moduledoc """
  Provider for Claude-subscription-backed execution via `claude -p` (headless
  print mode).

  This provider treats Claude Code as a structured completion backend rather
  than a full agent runtime. Alloy remains responsible for the tool loop,
  while Claude Code receives the current transcript and available tool
  definitions, then returns JSON describing either a final assistant response
  or one or more tool calls.

  ## Config

  Required:
  - `:model` - Claude model name or alias (for example `"claude-sonnet-5"`,
    `"sonnet"`, `"opus"`)

  Optional:
  - `:claude_bin` - Executable path (default: `"claude"`)
  - `:workdir` - Directory passed to `claude` (defaults to a temp dir). Always
    a throwaway directory unless overridden, so no `CLAUDE.md` from an
    unrelated project is auto-discovered from the working directory. Pass the
    *same* stable directory on every call for one conversation to get the
    `--resume` cache benefit described below - the default (fresh temp dir
    per call) makes `--resume` correct but free of any cost benefit.
  - `:config_dir` - Override `CLAUDE_CONFIG_DIR` for the invocation. Not set
    by default - see the macOS note below.
  - `:settings_path` - Passed through as `--settings <path>` when present
  - `:tmp_dir` - Parent for the provider's temp working directory
    (default: `System.tmp_dir!/0`)
  - `:timeout_ms` - How long a `claude` invocation may go without writing
    any output before it is stopped (default: `120_000`). Restarts with every
    chunk, so a long reply that keeps streaming is not cut off.
  - `:max_run_ms` - The most one invocation may run in total, streaming or not
    (default: 30 minutes)
  - `:receive_timeout` - Optional turn deadline timeout injected by Alloy's
    retry loop; when present it caps `:timeout_ms`
  - `:command_runner` - Test hook matching `System.cmd/3`
  - `:system_prompt` - Appended to the session via `--append-system-prompt`
    (in addition to being embedded in the transcript payload, same as Codex)

  ## Tool suppression

  Every invocation is run with `--tools ""`, `--strict-mcp-config`,
  `--safe-mode`, and `--permission-prompts none`. This is load-bearing, not a
  hardening afterthought: if Claude Code retained any of its own built-in
  tools it would go do the requested work itself and return a prose summary,
  instead of returning `tool_use` blocks for Alloy's loop to execute. That
  silently breaks the provider contract - the response still validates
  against the schema, so it fails as *wrong output*, not as an error. These
  flags are fixed and are not exposed as config; there is no supported way
  to give this provider real tool access.

  **Deliberately not `--permission-mode plan`.** An earlier version of this
  provider set it, reasoning it was the closest documented value to
  "deny-equivalent." It is not a permission *level* at all - it is Claude
  Code's actual interactive Plan Mode persona, and it actively breaks
  structured output: combined with `--json-schema` in a resumed or
  explicitly-`--session-id`'d call, the model started narrating its own
  planning workflow ("I'm in **plan mode**... explore, design, create a plan
  file, get approval... the StructuredOutput tool is meant to be called once
  at the *end*") instead of answering, in a response that still validated
  against the schema - the exact "fails as wrong output, not an error"
  failure mode this section opens with, caught live rather than in theory.
  `--tools ""` alone already guarantees zero tool capability regardless of
  permission mode, so dropping the flag costs nothing; verified live that
  tool suppression, plain completions, and resumed completions all still
  behave correctly without it.

  `--safe-mode` additionally disables `CLAUDE.md` auto-discovery, skills,
  plugins, hooks, custom agents, and output styles for the invocation, without
  touching credentials. That matters here specifically because Codex's trick
  of copying `auth.json` into an isolated `CODEX_HOME` does not port to
  Claude Code on macOS: credentials there live in the Keychain, not a file, so
  pointing `CLAUDE_CONFIG_DIR` at an empty directory breaks login (confirmed
  empirically: `claude` reports "Not logged in"). `--safe-mode` gets the same
  isolation outcome (no ambient project config, no MCP passthrough) while
  leaving auth alone on every platform, so `:config_dir` is left unset by
  default rather than gated on `:os.type/0`. Pass `:config_dir` explicitly
  only if you deliberately want a specific `CLAUDE_CONFIG_DIR` for this
  invocation.

  ## Session continuation (`--resume`)

  Codex re-sends the entire transcript on every turn, with no cross-turn
  caching - and this provider started out doing the same. Measured against
  the real CLI, that costs roughly 7x more per follow-up turn than it needs
  to: `claude -p --resume <session_id>` genuinely continues a prior
  conversation (verified live - a codeword mentioned in turn 1 is recalled
  correctly in turn 2 with no re-statement) and, when the working directory
  is unchanged between calls, the shared prefix comes back as
  `cache_read_input_tokens` instead of `cache_creation_input_tokens` - a real
  prompt-cache hit, not just avoided re-transmission. Off-loop testing put a
  resumed follow-up turn at ~$0.0019 against ~$0.013 for the same turn sent
  fresh.

  So this provider now resumes automatically, using the exact mechanism
  `Alloy.Provider` was built for: `:provider_state`, already used by
  `Alloy.Provider.OpenAI` for its own `previous_response_id` continuation.
  Every successful turn returns `provider_state: %{session_id:, sent_upto:,
  prefix_hash:}`, which `Alloy.Agent.Turn` merges into `config` on the next
  call automatically - nothing else has to plumb it through.

  On each call:
  - If `config[:provider_state]` names a session and the first `sent_upto`
    entries of the current `messages` hash-match `prefix_hash`, only the
    messages *after* that point are serialized and sent with `--resume
    <session_id>` - not the whole history.
  - Otherwise (first call, a harness restart that resumed Alloy's own
    messages but lost the CLI-side session, or a middleware like
    `Alloy.Context.Compactor` rewriting earlier history so the hash no
    longer matches) this falls back to the original behavior: the full
    current `messages` list, no `--resume`, and a fresh session captured
    from the response for next time. Resuming is a pure optimization; on any
    doubt this provider prefers to pay full price over risking a resumed
    turn built on a transcript Claude Code's own session no longer matches.

  **The cache benefit requires a stable `:workdir` across calls.** Verified
  live: resuming from a *different* directory than the original call still
  correctly recalls conversation content (session lookup does not require a
  matching cwd), but the prompt cache is never reused - full price every
  time, even with `--exclude-dynamic-system-prompt-sections` (tried; did not
  help). If `:workdir` is left at its default (a fresh temp dir every call,
  same as Codex), `--resume` still works correctly but buys nothing - so a
  caller that wants the cost benefit must pass the *same* `:workdir` on
  every call for one conversation (CmsHarness's agents already have exactly
  this: one persistent working copy per agent for its whole lifetime).

  All per-invocation flags (`--tools`, `--safe-mode`, `--json-schema`,
  `--model`, `--append-system-prompt`, ...) are still sent on *every* call,
  resumed or not - Claude Code only resumes conversation content, not CLI
  flags. Confirmed live that caching survives `--append-system-prompt` being
  present on both calls, which matters here specifically because CmsHarness
  always sets `:system_prompt`.

  ## Notes

  - Authentication is handled by the local `claude` CLI login state
    (subscription OAuth or API key) - this provider never reads, copies, or
    otherwise touches credentials.
  - Usage accounting reflects the real numbers from the CLI's
    `--output-format json` envelope (`usage.input_tokens` /
    `usage.output_tokens`), unlike Codex's hardcoded zero usage, so
    `max_budget_cents` guards work against this provider. Codex's zero-usage
    note no longer applies; it reports real usage too.
  - `stream/4` streams for real: it runs `--output-format stream-json
    --include-partial-messages` and passes the reply's `text` to the callback
    as it arrives. Under `--json-schema` the reply streams as fragments of the
    StructuredOutput tool's JSON input rather than as text, so the
    provider decodes the growing `text` value out of it. The chunks always add up to the final `text`.
  """

  @behaviour Alloy.Provider

  alias Alloy.{Message, OSProcess}
  alias Alloy.Provider.ClaudeCode.StreamJson
  alias Alloy.Provider.{CliSession, Error}

  @default_timeout_ms 120_000
  @default_max_run_ms :timer.minutes(30)
  @default_claude_bin "claude"
  @output_truncation 4_000
  @error_truncation 2_000
  @zero_usage %{input_tokens: 0, output_tokens: 0}

  # Matches any `\X` where X is NOT a valid JSON single-character escape
  # (valid set: " \ / b f n r t u). Used by the decode repair pass.
  @response_schema %{
    type: "object",
    additionalProperties: false,
    properties: %{
      stop_reason: %{type: "string", enum: ["end_turn", "tool_use"]},
      text: %{type: "string"},
      tool_calls: %{
        type: "array",
        items: %{
          type: "object",
          additionalProperties: false,
          properties: %{
            call_id: %{type: "string"},
            name: %{type: "string"},
            arguments: %{type: "object"}
          },
          required: ["call_id", "name", "arguments"]
        }
      }
    },
    required: ["stop_reason", "text", "tool_calls"]
  }

  # Pre-encoded at compile time - the schema is static, no need to
  # re-encode it on every `complete/3` call. `--json-schema` takes the JSON
  # inline on the command line (verified against `claude --help`; there is
  # no file-path form - passing a path fails with "not valid JSON").
  @response_schema_json Jason.encode!(@response_schema)

  @typedoc """
  Configuration for the Claude Code provider. See the module doc for field
  semantics.
  """
  @type config :: %{
          required(:model) => String.t(),
          optional(:claude_bin) => String.t(),
          optional(:workdir) => String.t(),
          optional(:config_dir) => String.t(),
          optional(:settings_path) => String.t(),
          optional(:tmp_dir) => String.t(),
          optional(:timeout_ms) => pos_integer(),
          optional(:max_run_ms) => pos_integer(),
          optional(:receive_timeout) => pos_integer(),
          optional(:system_prompt) => String.t(),
          optional(:command_runner) => (String.t(), [String.t()], keyword() ->
                                          {String.t(), integer()}),
          optional(:provider_state) => map()
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config), do: run(messages, tool_defs, config, nil)

  # `on_chunk` nil is a plain completion; a function streams the reply text
  # into it as `stream-json` delivers it.
  defp run(messages, tool_defs, config, on_chunk) do
    messages
    |> run_turn(tool_defs, config, on_chunk)
    |> to_provider_error()
  end

  # Every built-in provider fails with %Alloy.Provider.Error{}; the steps below
  # still describe their failures as strings.
  defp to_provider_error({:error, message}) when is_binary(message) do
    kind = if Error.overflow_text?(message), do: :context_overflow, else: :unknown
    {:error, %Error{kind: kind, message: message}}
  end

  defp to_provider_error(result), do: result

  defp run_turn(messages, tool_defs, config, on_chunk) do
    case prepare_paths(config) do
      {:ok, paths} ->
        try do
          resume = CliSession.plan(config, messages)
          prompt = build_turn_prompt(resume, messages, tool_defs, config)

          with :ok <- File.write(paths.prompt_path, prompt),
               {:ok, command_result} <-
                 run_claude(prompt, paths, config, resume, tool_defs, on_chunk),
               {:ok, completion} <- finish_turn(command_result, paths, config, messages) do
            {:ok, remember_tools(completion, tool_defs)}
          end
        after
          cleanup_paths(paths)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt({:resume, _session_id, new_messages}, _messages, tool_defs, config) do
    known = (Map.get(config, :provider_state) || %{}) |> Map.get(:tools_hash)
    changed = if known == tools_hash(tool_defs), do: nil, else: tool_defs
    build_incremental_prompt(new_messages, changed, config)
  end

  defp build_turn_prompt(:fresh, messages, tool_defs, config) do
    build_prompt(messages, tool_defs, config)
  end

  # The session already holds the tool definitions it was last sent, so a
  # resumed call repeats them only when they changed. Re-sending ~12k chars of
  # tool schema on every call is what filled a resumed session to its
  # compaction limit in hours.
  defp remember_tools(%{provider_state: %{session_id: id} = state} = completion, tool_defs)
       when is_binary(id),
       do: %{completion | provider_state: Map.put(state, :tools_hash, tools_hash(tool_defs))}

  defp remember_tools(%{provider_state: %{} = state} = completion, _tool_defs),
    do: %{completion | provider_state: Map.put(state, :tools_hash, nil)}

  defp tools_hash(tool_defs), do: :erlang.phash2(Enum.map(tool_defs, &serialize_tool_def/1))

  @impl true
  @spec stream([Message.t()], [Alloy.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    run(messages, tool_defs, config, on_chunk)
  end

  # A tool the model called natively, which the CLI was stopped before refusing.
  #
  # The model named a real tool, only through the wrong channel, so it is run
  # the way it would have been from `tool_calls`. The session is not resumed:
  # it ends on a tool call with no result, and the next turn goes out fresh with
  # this call and its result as ordinary transcript.
  defp finish_turn(%{stream: %StreamJson{call: %{} = call}}, _paths, config, _messages) do
    {:ok,
     %{
       stop_reason: :tool_use,
       messages: [
         Message.assistant_blocks([
           %{type: "tool_use", id: call.id, name: call.name, input: call.input}
         ])
       ],
       usage: @zero_usage,
       response_metadata: %{backend: "claude_code_print", model: Map.get(config, :model)},
       provider_state: CliSession.reset()
     }}
  end

  defp finish_turn(command_result, paths, config, messages) do
    with {:ok, {structured_output, envelope}} <- read_payload_or_error(paths, command_result),
         {:ok, completion} <- parse_payload(structured_output, config, envelope, messages) do
      finish_stream(command_result, structured_output)
      {:ok, forget_stray_session(completion, command_result)}
    end
  end

  # The model called a tool the CLI does not have and was told "No such tool
  # available". Resuming that session keeps the refusal — and whatever the model
  # concluded from it — in front of every later turn.
  defp forget_stray_session(completion, %{stream: %StreamJson{stray?: true}}),
    do: %{completion | provider_state: CliSession.reset()}

  defp forget_stray_session(completion, _command_result), do: completion

  # Whatever of the final `text` the partial JSON did not already deliver, so
  # the chunks always add up to the reply. Normally nothing; all of it if the
  # CLI sent no partial messages. If what streamed is not a prefix of the final
  # text (the model called StructuredOutput twice), there is no remainder to
  # send that would make the two agree, so nothing is.
  defp finish_stream(%{stream: %StreamJson{on_chunk: on_chunk} = stream}, %{"text" => text})
       when is_function(on_chunk, 1) and is_binary(text) do
    if String.starts_with?(text, stream.streamed) and text != stream.streamed do
      streamed = byte_size(stream.streamed)
      stream.on_chunk.(binary_part(text, streamed, byte_size(text) - streamed))
    end

    :ok
  end

  defp finish_stream(_command_result, _structured_output), do: :ok

  defp prepare_paths(config) do
    base_dir = build_base_dir(config)

    case mkdir_base(base_dir) do
      :ok ->
        {:ok, build_paths(base_dir, config)}

      {:error, reason} ->
        _ = File.rm_rf(base_dir)
        {:error, reason}
    end
  end

  defp build_base_dir(config) do
    parent = Map.get(config, :tmp_dir) || System.tmp_dir!()
    Path.join(parent, "alloy-claude-code-#{System.unique_integer([:positive])}")
  end

  defp mkdir_base(base_dir) do
    case File.mkdir_p(base_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "failed to prepare Claude Code temp directory: #{inspect(reason)}"}
    end
  end

  defp build_paths(base_dir, config) do
    %{
      base_dir: base_dir,
      prompt_path: Path.join(base_dir, "prompt.txt"),
      stderr_path: Path.join(base_dir, "stderr.txt"),
      workdir: Map.get(config, :workdir, base_dir),
      config_dir: Map.get(config, :config_dir)
    }
  end

  defp cleanup_paths(%{base_dir: base_dir}) do
    _ = File.rm_rf(base_dir)
    :ok
  end

  defp run_claude(prompt, paths, config, resume, tool_defs, on_chunk) do
    executable = Map.get(config, :claude_bin, @default_claude_bin)
    timeout = effective_timeout(config)

    args =
      [
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--json-schema",
        @response_schema_json,
        "--tools",
        "",
        "--strict-mcp-config",
        "--safe-mode",
        "--permission-prompts",
        "none"
      ]
      |> maybe_append_model(config)
      |> maybe_append_system_prompt(config)
      |> maybe_append_settings(config)
      |> maybe_append_resume(resume)
      |> append_prompt_arg(prompt, config)

    stream = StreamJson.new(on_chunk, Enum.map(tool_defs, & &1.name))

    if injected_runner?(config) do
      run_injected(config, executable, args, paths, stream)
    else
      run_port(executable, args, paths, {timeout, max_run(config)}, stream)
    end
  end

  defp max_run(config), do: Map.get(config, :max_run_ms, @default_max_run_ms)

  defp effective_timeout(config) do
    timeout_ms = Map.get(config, :timeout_ms, @default_timeout_ms)

    case Map.get(config, :receive_timeout) do
      receive_timeout when is_integer(receive_timeout) and receive_timeout > 0 ->
        min(receive_timeout, timeout_ms)

      _ ->
        timeout_ms
    end
  end

  # Test path: the caller supplies a synchronous function matching
  # `System.cmd/3`. Its return value is treated as stdout - unlike Codex,
  # there is no output file to intercept, since Claude Code's structured
  # payload comes back on stdout itself.
  defp run_injected(config, executable, args, paths, stream) do
    runner = Map.fetch!(config, :command_runner)
    opts = [cd: paths.workdir, stderr_to_stdout: false]

    case runner.(executable, args, opts) do
      {output, status} when is_binary(output) and is_integer(status) ->
        {:ok, %{output: output, status: status, stream: StreamJson.feed(stream, output)}}

      other ->
        {:error, "claude exec returned unexpected result: #{inspect(other)}"}
    end
  rescue
    error in ErlangError ->
      {:error, "claude exec failed to start: #{Exception.message(error)}"}
  end

  # Real path: spawn via Port so we capture the OS pid and can kill the
  # subprocess on timeout. `exec env ... claude ...` makes the shell process
  # replace itself with env, which replaces itself with claude - so
  # `Port.info(:os_pid)` returns claude's own pid rather than a shell pid
  # whose children we'd otherwise orphan.
  #
  # stderr is redirected to a file by the shell command itself (not merged
  # into stdout via Port options) so that stray diagnostic output can never
  # corrupt the single JSON result object `--output-format json` writes to
  # stdout.
  defp run_port(executable, args, paths, {timeout, max_run}, stream) do
    shell_command = build_port_command(executable, args, paths)

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          {:args, ["-lc", shell_command]},
          {:cd, paths.workdir},
          :binary,
          :exit_status,
          :use_stdio
        ]
      )

    # Port.info/2 returns nil when the process already exited - its output
    # and exit_status messages are still in the mailbox, so collect them;
    # there is just no OS pid left to kill on timeout.
    now = System.monotonic_time(:millisecond)

    limits = %{
      idle: timeout,
      quiet_until: now + timeout,
      max_run: max_run,
      run_until: now + max_run
    }

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    collect_port(port, os_pid, limits, [], stream)
  rescue
    error in ErlangError ->
      {:error, "claude exec failed to start: #{Exception.message(error)}"}
  end

  defp build_port_command(executable, args, paths) do
    env_args =
      [{"CLAUDE_CONFIG_DIR", paths.config_dir}]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" ", fn {key, value} -> shell_escape("#{key}=#{value}") end)

    "exec env " <>
      env_args <>
      " " <>
      Enum.map_join([executable | args], " ", &shell_escape/1) <>
      " < " <>
      shell_escape(paths.prompt_path) <>
      " 2> " <>
      shell_escape(paths.stderr_path)
  end

  # Two limits. `:timeout_ms` is how long the CLI may go without writing
  # anything, and restarts on every chunk: a run is cut off for going quiet,
  # not for being long. It was a deadline on the whole run, and a slow but
  # streaming reply on a large context was killed at three minutes, every turn,
  # with nothing produced (eb09b076). `:max_run_ms` is the deadline, for a run
  # that writes forever.
  defp collect_port(port, os_pid, limits, acc, stream) do
    now = System.monotonic_time(:millisecond)
    remaining = max(min(limits.quiet_until, limits.run_until) - now, 0)

    receive do
      {^port, {:data, data}} when is_binary(data) ->
        case StreamJson.feed(stream, data) do
          # The model called one of Alloy's tools natively. Stopped here, before
          # the CLI's refusal reaches it; `finish_turn/4` runs the call instead.
          %StreamJson{call: %{}} = stream ->
            _ = kill_os_process(os_pid)
            _ = close_and_drain(port)
            {:ok, %{output: IO.iodata_to_binary([acc, data]), status: nil, stream: stream}}

          stream ->
            limits = %{limits | quiet_until: System.monotonic_time(:millisecond) + limits.idle}
            collect_port(port, os_pid, limits, [acc, data], stream)
        end

      {^port, {:exit_status, status}} ->
        {:ok, %{output: IO.iodata_to_binary(acc), status: status, stream: stream}}
    after
      remaining ->
        _ = kill_os_process(os_pid)
        _ = close_and_drain(port)
        {:error, %Error{kind: :timeout, message: timeout_message(limits)}}
    end
  end

  # Both start `claude exec timed out after <ms>ms`, which callers read a
  # timeout off; what follows says which limit it was.
  defp timeout_message(%{run_until: run_until, max_run: max_run} = limits) do
    if System.monotonic_time(:millisecond) >= run_until do
      "claude exec timed out after #{max_run}ms, its limit for one run, while still writing"
    else
      "claude exec timed out after #{limits.idle}ms with no output"
    end
  end

  # SIGTERM with a 100ms grace window, then SIGKILL, to claude's whole process
  # group. Best-effort - if claude has already exited, both are no-ops.
  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) do
    :ok = OSProcess.signal_group(os_pid, "TERM")
    Process.sleep(100)
    OSProcess.signal_group(os_pid, "KILL")
  end

  defp close_and_drain(port) do
    _ =
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end

    drain_port_messages(port)
  end

  defp drain_port_messages(port) do
    receive do
      {^port, _} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end

  # Unlike Codex, the real invocation never gets a positional prompt arg -
  # `claude -p` reads the prompt from stdin automatically whenever stdin is
  # not a TTY and no positional prompt is given (verified: no `-` marker is
  # needed, and passing one would be read literally as the prompt text). The
  # injected test runner still receives the prompt as a plain arg for easy
  # assertions, matching the Codex test convention.
  defp append_prompt_arg(args, prompt, config) do
    if injected_runner?(config) do
      args ++ [prompt]
    else
      args
    end
  end

  # An explicit `:command_runner` in config means the caller is driving
  # process execution themselves (almost always a test). Real usage goes
  # through the shell wrapper so we can inject env and stdin-feed the prompt.
  defp injected_runner?(config), do: Map.has_key?(config, :command_runner)

  defp read_payload_or_error(paths, %{status: status, output: stdout}) do
    case parse_envelope(stdout) do
      {:ok, %{"is_error" => false, "structured_output" => structured_output} = envelope}
      when is_map(structured_output) ->
        {:ok, {structured_output, envelope}}

      {:ok, envelope} ->
        {:error, claude_error(status, envelope, paths)}

      {:error, _reason} ->
        {:error, claude_error(status, stdout, paths)}
    end
  end

  # `--output-format json` writes exactly one JSON result object to stdout in
  # every observed case (success, refused model, missing auth), but we don't
  # assume that holds forever - scan from the last line backward for the
  # first one that decodes to a `"type": "result"` object, so stray
  # non-JSON output earlier on stdout can't break parsing.
  defp parse_envelope(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.reduce_while({:error, "no JSON result object found in claude output"}, fn line, acc ->
      case Jason.decode(line) do
        {:ok, %{"type" => "result"} = envelope} -> {:halt, {:ok, envelope}}
        _ -> {:cont, acc}
      end
    end)
  end

  defp claude_error(status, %{"result" => result}, paths) when is_binary(result) do
    build_claude_error(status, result, paths)
  end

  defp claude_error(status, envelope, paths) when is_map(envelope) do
    build_claude_error(status, inspect(envelope), paths)
  end

  defp claude_error(status, stdout, paths) when is_binary(stdout) do
    build_claude_error(status, stdout, paths)
  end

  defp build_claude_error(status, message, paths) do
    stderr = read_stderr(paths)

    combined =
      [String.trim(to_string(message)), String.trim(stderr)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" | stderr: ")

    "claude exec failed with status #{status}: #{truncate(combined, @error_truncation)}"
  end

  defp read_stderr(%{stderr_path: path}) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> ""
    end
  end

  defp parse_payload(
         %{"stop_reason" => "end_turn", "text" => text, "tool_calls" => tool_calls},
         config,
         envelope,
         messages
       )
       when is_binary(text) and is_list(tool_calls) do
    if tool_calls == [] do
      reply = Message.assistant(unescape_overencoded(text))

      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [reply],
         usage: extract_usage(envelope),
         response_metadata: response_metadata(config, envelope),
         provider_state: CliSession.next_state(messages, reply, Map.get(envelope, "session_id"))
       }}
    else
      {:error, "Claude Code returned tool_calls for an end_turn response"}
    end
  end

  # A tool_use that names no tool. This failed the turn, and the agent's whole
  # reply became the error string, so the request it was answering was lost:
  # six times on metric_flow from 09-23 to 10-01 (8e9a1d83).
  #
  # With text, the text is the reply and the turn ends on it — it has already
  # streamed to the user, and `Alloy.Provider.Retry` never retries once chunks
  # are out. With none, there is nothing to show, so the error is
  # `malformed_reply:`, which `Retry` asks again for.
  defp parse_payload(
         %{"stop_reason" => "tool_use", "text" => text, "tool_calls" => []} = payload,
         config,
         envelope,
         messages
       )
       when is_binary(text) do
    if String.trim(text) == "" do
      {:error, "malformed_reply: Claude Code returned tool_use without any tool calls"}
    else
      parse_payload(%{payload | "stop_reason" => "end_turn"}, config, envelope, messages)
    end
  end

  defp parse_payload(
         %{"stop_reason" => "tool_use", "text" => text, "tool_calls" => tool_calls},
         config,
         envelope,
         messages
       )
       when is_binary(text) and is_list(tool_calls) do
    with {:ok, blocks} <- parse_tool_blocks(text, tool_calls) do
      reply = Message.assistant_blocks(blocks)

      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [reply],
         usage: extract_usage(envelope),
         response_metadata: response_metadata(config, envelope),
         provider_state: CliSession.next_state(messages, reply, Map.get(envelope, "session_id"))
       }}
    end
  end

  defp parse_payload(payload, _config, _envelope, _messages) do
    {:error, "unexpected Claude Code response payload: #{inspect(payload)}"}
  end

  defp parse_tool_blocks(text, tool_calls) do
    blocks =
      tool_calls
      |> Enum.with_index(1)
      |> Enum.reduce_while([], fn {tool_call, index}, acc ->
        case build_tool_block(tool_call, index) do
          {:ok, block} -> {:cont, [block | acc]}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case blocks do
      {:error, _} = err -> err
      blocks -> finalize_tool_blocks(text, Enum.reverse(blocks))
    end
  end

  defp build_tool_block(tool_call, index) do
    with {:ok, call_id} <- tool_call_id(tool_call, index),
         {:ok, name} <- fetch_string(tool_call, "name"),
         {:ok, arguments} <- fetch_arguments(tool_call) do
      {:ok, %{type: "tool_use", id: call_id, name: name, input: arguments}}
    end
  end

  defp finalize_tool_blocks(text, tool_blocks) do
    case text |> unescape_overencoded() |> String.trim() do
      "" -> {:ok, tool_blocks}
      trimmed -> {:ok, [%{type: "text", text: trimmed} | tool_blocks]}
    end
  end

  # The model writes `text` as a JSON string value, and now and then escapes it
  # twice: the value arrives holding a literal `\n` where it meant a line
  # break, and `\"` where it meant a quote. Measured 2026-09-27: 5 of 14,824
  # replies in a week, three of them in one conversation, every one rendered
  # to the user as a single line of `\n\n- `. The Claude Code transcript shows
  # the escaping in the model's own StructuredOutput call, so nothing here
  # added it.
  #
  # A reply with no line break that decodes cleanly as the body of a JSON
  # string is taken as one encoded twice. One with a real line break, or with
  # an unescaped quote, is not, and is left as written.
  defp unescape_overencoded(text) do
    with false <- String.contains?(text, "\n"),
         true <- String.contains?(text, "\\n"),
         {:ok, decoded} when is_binary(decoded) <- Jason.decode(~s("#{text}")) do
      decoded
    else
      _ -> text
    end
  end

  defp tool_call_id(tool_call, index) do
    case Map.get(tool_call, "call_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:ok, "call_#{index}"}
      other -> {:error, "invalid Claude Code tool call id: #{inspect(other)}"}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, "invalid Claude Code field #{inspect(key)}: #{inspect(other)}"}
    end
  end

  # The arguments themselves.
  #
  # The schema used to ask for `arguments_json`: a *string* containing JSON, so
  # every tool call was encoded twice and the model had to escape its own
  # payload for a second pass. Fine for a browser selector, unworkable for
  # source code, where quotes, newlines and regex backslashes all have to
  # survive being escaped, embedded, and parsed back out.
  #
  # It did not survive. Measured 2026-09-08: a coding agent produced three
  # messages in fifteen minutes and all three were `invalid Claude Code
  # arguments_json` — every attempt to act rejected before it happened, no files
  # written, 4 tool calls against 1,847 messages across three agents in six
  # hours. A QA agent on the same model passing short browser arguments was
  # mostly fine, which is what made it look like a problem with one agent.
  #
  # `repair_backslash_escapes/1` was the previous answer and conceded its own
  # limit: it "does NOT help cases where Claude *under-escapes* an otherwise
  # valid sequence... Fixing that class of error needs a prompt-level
  # constraint, not a post-hoc patch." A schema is that constraint, so the
  # repair pass and the second decode are gone with it.
  #
  # Verified against the real CLI: asking for `arguments` as an object returns
  # `{"path":"lib/a.ex","content":"defmodule A do\n  @re ~r/\\d+/\nend"}` —
  # one encoding, correctly escaped.
  defp fetch_arguments(%{"arguments" => arguments}) when is_map(arguments) do
    {:ok, arguments}
  end

  defp fetch_arguments(%{"arguments" => other}) do
    {:error, "Claude Code tool call arguments must be an object, got: #{inspect(other)}"}
  end

  defp fetch_arguments(_map) do
    {:error, "Claude Code tool call is missing its arguments object"}
  end

  # Including the cached halves, which are nearly all of it.
  #
  # Claude Code bills the request in three parts and reports `input_tokens` as
  # only the uncached remainder. Measured against the real CLI on 2026-09-21: a
  # first turn carrying a 3.6KB appended system prompt came back
  # `input_tokens: 4`, `cache_creation_input_tokens: 19_628`,
  # `cache_read_input_tokens: 25_914` — four tokens against a real input of
  # forty-five thousand. A caller adding up `input_tokens` to bill somebody, or
  # to decide a prompt is too long, is reading a number four orders of
  # magnitude out.
  #
  # `Alloy.Usage` has carried both fields all along; this filled neither, so the
  # cache hit `--resume` exists to buy was invisible in the one place a caller
  # looks for it. `response_metadata/2` reports them too and still does — that
  # is the Claude-Code-specific view, and this is the cross-provider one.
  defp extract_usage(envelope) do
    case Map.get(envelope, "usage") do
      %{"input_tokens" => input, "output_tokens" => output}
      when is_integer(input) and is_integer(output) ->
        %{
          input_tokens: input,
          output_tokens: output,
          cache_creation_input_tokens: cached(envelope, "cache_creation_input_tokens"),
          cache_read_input_tokens: cached(envelope, "cache_read_input_tokens")
        }

      _ ->
        @zero_usage
    end
  end

  # Absent and zero are the same thing to a total, and a provider that does not
  # report caching should not look like one whose cache never hit.
  defp cached(envelope, key) do
    case envelope |> Map.get("usage", %{}) |> Map.get(key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  defp response_metadata(config, envelope) do
    usage = Map.get(envelope, "usage", %{})

    %{
      backend: "claude_code_print",
      model: Map.get(config, :model),
      session_id: Map.get(envelope, "session_id"),
      total_cost_usd: Map.get(envelope, "total_cost_usd"),
      duration_ms: Map.get(envelope, "duration_ms"),
      # Not in `usage:` (Alloy's cross-provider `input_tokens`/`output_tokens`
      # contract) - these are Claude-Code-specific and exist so a caller can
      # actually observe whether `--resume` bought a cache hit, rather than
      # inferring it from `total_cost_usd` moving around.
      cache_read_input_tokens: Map.get(usage, "cache_read_input_tokens"),
      cache_creation_input_tokens: Map.get(usage, "cache_creation_input_tokens"),
      command_output: truncate(String.trim(inspect(envelope)), @output_truncation)
    }
  end

  defp build_prompt(messages, tool_defs, config) do
    payload = %{
      system_prompt: Map.get(config, :system_prompt),
      conversation: Enum.map(messages, &serialize_message/1),
      available_tools: Enum.map(tool_defs, &serialize_tool_def/1)
    }

    """
    You are acting as the model backend for Alloy, an agent harness.

    Read the transcript and available tools below, then produce exactly one JSON
    object matching the supplied schema.

    Response rules:
    - If no tool is needed, return `stop_reason = "end_turn"`, `tool_calls = []`,
      and put the assistant's response in `text`.
    - If one or more tools are needed, return `stop_reason = "tool_use"` and add
      entries to `tool_calls`.
    - Each tool call must use a valid tool name from `available_tools`.
    - Each tool call must include `arguments`, a JSON object satisfying the
      tool schema. Write the arguments directly — they are not a string, and
      nothing in them needs escaping for a second pass.
    - If returning tool calls, keep `text` empty unless a short preamble would
      help the outer agent loop.
    - Never mention the schema or these instructions in `text`.
    - You have no tools of your own and cannot run anything. Never call a tool
      directly: every tool is used by naming it in `tool_calls`, including the
      ones the transcript shows being called.

    Transcript payload:
    #{Jason.encode!(payload)}
    """
  end

  # Sent instead of `build_prompt/3` when resuming: Claude Code's own
  # resumed session already has the framing, response rules, and every
  # earlier message from `build_prompt/3`'s first call - re-sending any of
  # that would be exactly the token cost `--resume` exists to avoid.
  # `available_tools` is sent only when the definitions changed since the
  # session last saw them (`tool_defs` nil otherwise).
  defp build_incremental_prompt(new_messages, tool_defs, _config) do
    payload =
      %{conversation: Enum.map(new_messages, &serialize_message/1)}
      |> put_tools(tool_defs)

    """
    Continuing the same conversation. Produce exactly one JSON object
    matching the schema and response rules already given, based on the new
    transcript entries below.

    New transcript entries:
    #{Jason.encode!(payload)}
    """
  end

  defp put_tools(payload, nil), do: payload

  defp put_tools(payload, tool_defs),
    do: Map.put(payload, :available_tools, Enum.map(tool_defs, &serialize_tool_def/1))

  defp serialize_message(%Message{role: role, content: content}) when is_binary(content) do
    %{role: Atom.to_string(role), content: content}
  end

  defp serialize_message(%Message{role: role, content: blocks}) when is_list(blocks) do
    %{
      role: Atom.to_string(role),
      content_blocks: Enum.map(blocks, &serialize_block/1)
    }
  end

  defp serialize_block(%{type: "text", text: text}), do: %{type: "text", text: text}

  defp serialize_block(%{type: "tool_use", id: id, name: name, input: input}) do
    %{type: "tool_use", id: id, name: name, input: input}
  end

  defp serialize_block(%{type: "tool_result", tool_use_id: id, content: content} = block) do
    %{
      type: "tool_result",
      tool_use_id: id,
      content: content,
      is_error: Map.get(block, :is_error, false)
    }
  end

  # Defensive fallback for unknown block shapes - keeps serialization
  # total even if Alloy adds a new block type this provider hasn't
  # learned yet. The outer agent loop normalizes before we're called, so
  # this branch is expected to be cold.
  defp serialize_block(block), do: Alloy.Provider.stringify_keys(block)

  defp serialize_tool_def(%{name: name, description: description, input_schema: input_schema}) do
    %{
      name: name,
      description: description,
      input_schema: input_schema
    }
  end

  defp maybe_append_model(args, config) do
    case Map.get(config, :model) do
      nil -> args
      model -> args ++ ["--model", model]
    end
  end

  defp maybe_append_system_prompt(args, config) do
    case Map.get(config, :system_prompt) do
      prompt when is_binary(prompt) and prompt != "" ->
        args ++ ["--append-system-prompt", prompt]

      _ ->
        args
    end
  end

  defp maybe_append_settings(args, config) do
    case Map.get(config, :settings_path) do
      nil -> args
      path -> args ++ ["--settings", path]
    end
  end

  defp maybe_append_resume(args, {:resume, session_id, _new_messages}) do
    args ++ ["--resume", session_id]
  end

  defp maybe_append_resume(args, :fresh), do: args

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  # `limit` is a character budget, not a byte budget - `String.slice/3`
  # respects grapheme boundaries so we never split a multibyte codepoint
  # mid-sequence and produce invalid UTF-8 in user-facing fields like
  # `response_metadata.command_output`.
  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      String.slice(text, 0, limit) <> "..."
    else
      text
    end
  end
end
