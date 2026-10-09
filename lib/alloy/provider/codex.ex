defmodule Alloy.Provider.Codex do
  @moduledoc """
  Provider for ChatGPT-plan-backed Codex execution via `codex exec`.

  This provider treats Codex as a structured completion backend rather than a
  full agent runtime. Alloy remains responsible for the tool loop, while Codex
  receives the current transcript and available tool definitions, then returns
  JSON describing either a final assistant response or one or more tool calls.

  ## Config

  Required:
  - `:model` - Codex model name (for example `"gpt-5.4"`)

  Optional:
  - `:codex_bin` - Executable path (default: `"codex"`)
  - `:workdir` - Directory passed to `codex exec` (defaults to a temp dir)
  - `:codex_home` - `CODEX_HOME` for the subprocess. Defaults to the
    inherited `CODEX_HOME`, or `~/.codex`.
  - `:profile` - Codex profile: layers `$CODEX_HOME/<name>.config.toml` on
    the user config (Codex CLI 0.134.0 and later). Selecting a profile loads
    the user config, including its MCP servers and plugins.
  - `:config_overrides` - `key=value` strings passed to `codex exec` as
    `-c` flags, for example `[~s(model_reasoning_effort="high")]`
  - `:tmp_dir` - Parent for the provider's temp working directory
    (default: `System.tmp_dir!/0`)
  - `:timeout_ms` - Timeout for a single `codex exec` invocation
    (default: `120_000`)
  - `:receive_timeout` - Optional cap on `:timeout_ms`. Alloy's retry loop
    passes the remaining turn deadline as `req_options: [receive_timeout: ms]`
    (the shape HTTP providers use); the smallest of the three wins.
  - `:command_runner` - Test hook matching `System.cmd/3`
  - `:system_prompt` - System prompt string

  ## Authentication

  Codex reads and refreshes its login in `CODEX_HOME`, so every call shares
  the same credentials as the `codex` CLI and refreshed tokens are kept.
  Requires Codex CLI 0.122.0 or later.

  Unless `:profile` is set, calls run with `--ignore-user-config` and
  `--ignore-rules`: `config.toml` (MCP servers, plugins, hooks, model
  settings) and execpolicy rules are not loaded. Codex still reads
  `$CODEX_HOME/AGENTS.md` and skills from `CODEX_HOME`. For full isolation,
  log in to a dedicated home once (`CODEX_HOME=~/.codex-alloy codex login`)
  and pass it as `:codex_home`. A dedicated home also keeps Alloy from
  sharing a refresh token with your interactive Codex sessions.

  If your credentials are in the OS keyring
  (`cli_auth_credentials_store = "keyring"`), pass
  `config_overrides: [~s(cli_auth_credentials_store="keyring")]`, since that
  setting lives in the ignored `config.toml`.

  ## Errors

  Failures of the `codex exec` process return `%Alloy.Provider.Error{}`
  with the same message text as before: `:timeout` (which the loop retries
  within the turn deadline), `:context_overflow` (the loop compacts and
  retries), or `:unknown`, which covers a missing executable and other
  failed runs, including a malformed Codex response.

  ## Notes

  - Usage comes from the `turn.completed` event of `codex exec --json`. As
    with every built-in provider, `:input_tokens` is uncached input; cache
    reads and writes are reported separately. `:reasoning_output_tokens` is
    part of `:output_tokens`. Counts include Codex's own instructions and
    tool definitions, not just the transcript.
  - Each call runs `codex exec` under `Alloy.TaskSupervisor`. A timeout, or
    the calling process exiting (a cancelled turn), stops codex and every
    process it started, and removes the call's temp files.
  - Streaming is emulated by running a normal completion and replaying the final
    text to the provided callback.
  """

  @behaviour Alloy.Provider

  alias Alloy.{Message, OSProcess}
  alias Alloy.Provider.Error

  @default_timeout_ms 120_000
  @default_codex_bin "codex"
  @output_truncation 4_000
  @error_truncation 2_000
  @zero_usage %{input_tokens: 0, output_tokens: 0}
  # How long codex gets to exit after SIGTERM before the group is killed.
  @term_grace_ms 100
  # The owning task replies by its deadline plus the kill grace; this only
  # bounds the wait if it stops responding.
  @reply_grace_ms 5_000

  # Matches any `\X` where X is NOT a valid JSON single-character escape
  # (valid set: " \ / b f n r t u). Used by the decode repair pass.
  @invalid_json_escape_re ~r{\\(?!["\\/bfnrtu])}

  # sh only wires up redirects: the prompt file on stdin (codex reads it to
  # EOF, which a port cannot send) and stderr to a file, so stdout carries
  # nothing but --json events. Paths and arguments are positional
  # parameters, never spliced into the script. `exec` keeps the port's OS
  # pid on codex itself.
  @launch_script ~S(prompt="$1"; stderr="$2"; shift 2; exec "$@" < "$prompt" 2> "$stderr")

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
            arguments_json: %{type: "string"}
          },
          required: ["call_id", "name", "arguments_json"]
        }
      }
    },
    required: ["stop_reason", "text", "tool_calls"]
  }

  # Pre-encoded at compile time — the schema is static, no need to
  # re-encode it on every `complete/3` call.
  @response_schema_json Jason.encode!(@response_schema)

  @typedoc """
  Configuration for the Codex provider. See the module doc for field semantics.
  """
  @type config :: %{
          required(:model) => String.t(),
          optional(:codex_bin) => String.t(),
          optional(:workdir) => String.t(),
          optional(:profile) => String.t(),
          optional(:codex_home) => String.t(),
          optional(:config_overrides) => [String.t()],
          optional(:tmp_dir) => String.t(),
          optional(:timeout_ms) => pos_integer(),
          optional(:receive_timeout) => pos_integer(),
          optional(:req_options) => keyword(),
          optional(:system_prompt) => String.t(),
          optional(:command_runner) => (String.t(), [String.t()], keyword() ->
                                          {String.t(), integer()})
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    prompt = build_prompt(messages, tool_defs, config)

    with {:ok, command_result} <- execute(prompt, codex_home(config), config),
         {:ok, payload} <- decode_payload(command_result, config) do
      parse_payload(payload, config, command_result)
    end
    |> to_provider_error()
  end

  # Every built-in provider fails with %Alloy.Provider.Error{}; the response
  # parsing steps above still describe their failures as strings.
  defp to_provider_error({:error, message}) when is_binary(message),
    do: {:error, %Error{message: message}}

  defp to_provider_error(result), do: result

  @impl true
  @spec stream([Message.t()], [Alloy.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    with {:ok, result} <- complete(messages, tool_defs, config),
         :ok <- emit_chunks(result, on_chunk) do
      {:ok, result}
    end
  end

  # A removed option raises, like every config mistake: ignoring :auth_path
  # would silently run Codex as whichever account the default CODEX_HOME holds.
  defp codex_home(%{auth_path: _auth_path}) do
    raise ArgumentError,
          "Alloy.Provider.Codex :auth_path was removed in Alloy 0.13; " <>
            "set :codex_home to the directory holding auth.json instead"
  end

  defp codex_home(%{codex_home: codex_home}) when is_binary(codex_home), do: codex_home
  defp codex_home(_config), do: nil

  # Test hook: a synchronous function matching `System.cmd/3`, run in the
  # caller with no timeout of its own.
  defp execute(prompt, codex_home, %{command_runner: runner} = config) do
    in_temp_dir(config, fn paths ->
      with :ok <- write_inputs(paths, prompt) do
        run_injected(runner, codex_args(paths, config) ++ [prompt], codex_home, paths, config)
      end
    end)
  end

  # The OS process belongs to a supervised task rather than the caller, so it
  # is stopped and its files removed even when the caller is killed (the
  # loop kills a cancelled turn, and `after` blocks do not run on a kill).
  defp execute(prompt, codex_home, config) do
    with :ok <- check_workdir(config) do
      caller = self()
      timeout = effective_timeout(config)

      task =
        Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
          own_run(caller, prompt, codex_home, config, timeout)
        end)

      case Task.yield(task, timeout + @reply_grace_ms) || Task.shutdown(task) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, %Error{message: "codex exec failed: #{inspect(reason)}"}}
        nil -> {:error, timed_out(timeout)}
      end
    end
  end

  # The port reports a missing directory only as "exit status 2" with the
  # reason on stderr, so check it up front for a clear error.
  defp check_workdir(%{workdir: workdir}) when is_binary(workdir) do
    if File.dir?(workdir),
      do: :ok,
      else: {:error, %Error{message: "Codex :workdir #{workdir} is not a directory"}}
  end

  defp check_workdir(_config), do: :ok

  defp own_run(caller, prompt, codex_home, config, timeout) do
    # Trapping exits lets a supervisor shutdown stop codex too.
    Process.flag(:trap_exit, true)
    caller_ref = Process.monitor(caller)
    deadline = System.monotonic_time(:millisecond) + timeout

    result =
      in_temp_dir(config, fn paths ->
        with :ok <- write_inputs(paths, prompt) do
          port = open_port(codex_args(paths, config) ++ ["-"], codex_home, paths, config)

          run = %{
            port: port,
            os_pid: OSProcess.os_pid(port),
            caller_ref: caller_ref,
            deadline: deadline,
            timeout: timeout
          }

          with {:ok, output, status} <- collect(run, []) do
            {:ok, command_result(output, read_stderr(paths), status, paths)}
          end
        end
      end)

    Process.demonitor(caller_ref, [:flush])
    result
  end

  defp in_temp_dir(config, fun) do
    parent = Map.get(config, :tmp_dir) || System.tmp_dir!()
    base_dir = Path.join(parent, "alloy-codex-#{System.unique_integer([:positive])}")

    # 0700: the prompt file holds the whole conversation, and the default
    # mode leaves it readable by other users on a shared /tmp.
    with :ok <- File.mkdir_p(base_dir),
         :ok <- File.chmod(base_dir, 0o700) do
      try do
        fun.(paths(base_dir, config))
      after
        _ = File.rm_rf(base_dir)
      end
    else
      {:error, reason} ->
        _ = File.rm_rf(base_dir)
        {:error, "failed to prepare Codex temp directory: #{inspect(reason)}"}
    end
  end

  defp paths(base_dir, config) do
    %{
      prompt_path: Path.join(base_dir, "prompt.txt"),
      schema_path: Path.join(base_dir, "response_schema.json"),
      last_message_path: Path.join(base_dir, "last_message.json"),
      stderr_path: Path.join(base_dir, "stderr.log"),
      workdir: Map.get(config, :workdir, base_dir)
    }
  end

  defp write_inputs(paths, prompt) do
    with :ok <- File.write(paths.schema_path, @response_schema_json) do
      File.write(paths.prompt_path, prompt)
    end
  end

  defp effective_timeout(config) do
    [
      Map.get(config, :timeout_ms) || @default_timeout_ms,
      Map.get(config, :receive_timeout),
      config |> Map.get(:req_options, []) |> Keyword.get(:receive_timeout)
    ]
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.min()
  end

  defp run_injected(runner, args, codex_home, paths, config) do
    opts = [cd: paths.workdir, env: codex_env(codex_home)]

    case runner.(codex_bin(config), args, opts) do
      {output, status} when is_binary(output) and is_integer(status) ->
        {:ok, command_result(output, "", status, paths)}

      other ->
        {:error, "codex exec returned unexpected result: #{inspect(other)}"}
    end
  rescue
    error in ErlangError -> {:error, not_runnable(config, Exception.message(error))}
  end

  defp open_port(args, codex_home, paths, config) do
    env = Enum.map(codex_env(codex_home), fn {key, value} -> "#{key}=#{value}" end)

    launch_args =
      ["-lc", @launch_script, "alloy-codex", paths.prompt_path, paths.stderr_path, "env"] ++
        env ++ [codex_bin(config) | args]

    Port.open(
      {:spawn_executable, "/bin/sh"},
      [{:args, launch_args}, {:cd, paths.workdir}, :binary, :exit_status, :use_stdio]
    )
  end

  # The deadline is absolute: checking it before each receive keeps a
  # steady stream of output from postponing the timeout.
  defp collect(run, acc) do
    case run.deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> receive_output(run, acc, remaining)
      _expired -> time_out(run)
    end
  end

  defp receive_output(%{port: port, caller_ref: caller_ref} = run, acc, remaining) do
    receive do
      {^port, {:data, data}} ->
        collect(run, [acc, data])

      {^port, {:exit_status, status}} ->
        {:ok, IO.iodata_to_binary(acc), status}

      {:DOWN, ^caller_ref, :process, _pid, reason} ->
        :ok = stop(run)
        {:error, %Error{message: "codex exec cancelled: caller exited (#{inspect(reason)})"}}

      {:EXIT, from, reason} when is_pid(from) ->
        :ok = stop(run)
        exit(reason)
    after
      remaining -> time_out(run)
    end
  end

  defp time_out(run) do
    :ok = stop(run)
    {:error, timed_out(run.timeout)}
  end

  # SIGTERM, a short grace for codex to exit, then SIGKILL for anything left
  # in the group. The port's process leads its own process group
  # (erl_child_setup calls setsid), so this reaches codex's children too.
  defp stop(%{os_pid: nil}), do: :ok

  defp stop(%{port: port, os_pid: os_pid}) do
    :ok = OSProcess.signal_group(os_pid, "TERM")

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @term_grace_ms -> :ok
    end

    OSProcess.signal_group(os_pid, "KILL")
  end

  defp timed_out(timeout),
    do: %Error{kind: :timeout, message: "codex exec timed out after #{timeout}ms"}

  defp read_stderr(paths) do
    case File.read(paths.stderr_path) do
      {:ok, stderr} -> stderr
      {:error, _reason} -> ""
    end
  end

  defp command_result(output, stderr, status, paths) do
    %{
      output: output,
      stderr: stderr,
      status: status,
      events: decode_events(output),
      last_message: File.read(paths.last_message_path)
    }
  end

  # `codex exec --json` writes one event object per line.
  defp decode_events(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => type} = event} when is_binary(type) -> [event]
        _other -> []
      end
    end)
  end

  defp codex_env(nil), do: [{"OTEL_SDK_DISABLED", "true"}]
  defp codex_env(codex_home), do: [{"OTEL_SDK_DISABLED", "true"}, {"CODEX_HOME", codex_home}]

  defp codex_bin(config), do: Map.get(config, :codex_bin, @default_codex_bin)

  # sh and env exit 127 when the executable is missing and 126 when it
  # cannot be run.
  defp codex_error(%{status: status} = command_result, config) when status in [126, 127],
    do: not_runnable(config, "status #{status}: #{detail(command_result)}")

  defp codex_error(%{status: status} = command_result, _config) do
    message = "codex exec failed with status #{status}: #{detail(command_result)}"
    kind = if Error.overflow_text?(message), do: :context_overflow, else: :unknown
    %Error{kind: kind, message: message}
  end

  defp not_runnable(config, detail) do
    %Error{
      message:
        "could not run codex executable #{inspect(codex_bin(config))}; install the Codex CLI " <>
          "or set :codex_bin (#{detail})"
    }
  end

  defp detail(command_result) do
    command_result
    |> failure_detail()
    |> String.trim()
    |> truncate(@error_truncation)
  end

  # turn.failed is the last event. Failures before the first event (bad
  # config, missing login) only reach stderr.
  defp failure_detail(%{events: events, stderr: stderr, output: output}) do
    case events |> Enum.reverse() |> Enum.find_value(&event_error/1) do
      message when is_binary(message) -> message
      nil when stderr == "" -> output
      nil -> stderr
    end
  end

  defp event_error(%{"type" => "turn.failed", "error" => %{"message" => message}})
       when is_binary(message),
       do: message

  defp event_error(%{"type" => "error", "message" => message}) when is_binary(message),
    do: message

  defp event_error(_event), do: nil

  # A payload counts even when codex exits non-zero; without one, a non-zero
  # exit is the error worth reporting.
  defp decode_payload(%{last_message: last_message, status: status} = command_result, config) do
    case decode_last_message(last_message) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} when status == 0 -> {:error, reason}
      {:error, _reason} -> {:error, codex_error(command_result, config)}
    end
  end

  defp decode_last_message({:ok, content}) do
    case Jason.decode(content) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, error} ->
        {:error, "failed to decode Codex response JSON: #{Exception.message(error)}"}
    end
  end

  defp decode_last_message({:error, reason}),
    do: {:error, "failed to read Codex response file: #{inspect(reason)}"}

  defp parse_payload(
         %{"stop_reason" => "end_turn", "text" => text, "tool_calls" => tool_calls},
         config,
         command_result
       )
       when is_binary(text) and is_list(tool_calls) do
    if tool_calls == [] do
      {:ok,
       %{
         stop_reason: :end_turn,
         messages: [Message.assistant(text)],
         usage: usage(command_result),
         response_metadata: response_metadata(config, command_result)
       }}
    else
      {:error, "Codex returned tool_calls for an end_turn response"}
    end
  end

  defp parse_payload(
         %{"stop_reason" => "tool_use", "text" => text, "tool_calls" => tool_calls},
         config,
         command_result
       )
       when is_binary(text) and is_list(tool_calls) do
    with {:ok, blocks} <- parse_tool_blocks(text, tool_calls) do
      {:ok,
       %{
         stop_reason: :tool_use,
         messages: [Message.assistant_blocks(blocks)],
         usage: usage(command_result),
         response_metadata: response_metadata(config, command_result)
       }}
    end
  end

  defp parse_payload(payload, _config, _command_result) do
    {:error, "unexpected Codex response payload: #{inspect(payload)}"}
  end

  defp parse_tool_blocks(text, tool_calls) do
    tool_calls
    |> Enum.with_index(1)
    |> Enum.reduce_while([], fn {tool_call, index}, acc ->
      case build_tool_block(tool_call, index) do
        {:ok, block} -> {:cont, [block | acc]}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> finalize_reduced_tool_blocks(text)
  end

  defp finalize_reduced_tool_blocks({:error, _} = err, _text), do: err

  defp finalize_reduced_tool_blocks(blocks, text),
    do: finalize_tool_blocks(text, Enum.reverse(blocks))

  defp build_tool_block(tool_call, index) do
    with {:ok, call_id} <- tool_call_id(tool_call, index),
         {:ok, name} <- fetch_string(tool_call, "name"),
         {:ok, arguments} <- fetch_arguments(tool_call) do
      {:ok, %{type: "tool_use", id: call_id, name: name, input: arguments}}
    end
  end

  defp finalize_tool_blocks(_text, []) do
    {:error, "Codex returned tool_use without any tool calls"}
  end

  defp finalize_tool_blocks(text, tool_blocks) do
    case String.trim(text) do
      "" -> {:ok, tool_blocks}
      trimmed -> {:ok, [%{type: "text", text: trimmed} | tool_blocks]}
    end
  end

  defp tool_call_id(tool_call, index) do
    case Map.get(tool_call, "call_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:ok, "call_#{index}"}
      other -> {:error, "invalid Codex tool call id: #{inspect(other)}"}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, "invalid Codex field #{inspect(key)}: #{inspect(other)}"}
    end
  end

  defp fetch_arguments(map) do
    with {:ok, json} <- fetch_string(map, "arguments_json"),
         {:ok, decoded} when is_map(decoded) <- decode_arguments_json(json) do
      {:ok, decoded}
    else
      {:ok, _non_map} -> {:error, "Codex tool call arguments must decode to a JSON object"}
      {:error, _reason} = err -> err
    end
  end

  # Codex occasionally emits strings containing invalid JSON escape sequences
  # — most often `\d`, `\s`, `\p`, `\A` from regex source inside code payloads.
  # Valid single-character JSON escapes after `\` are: " \ / b f n r t u.
  # If the first decode fails, we double any other `\X` and retry.
  #
  # This does NOT help cases where Codex *under-escapes* an otherwise valid
  # sequence (e.g. emits `\n` when the intent was a literal backslash-n):
  # Jason decodes that successfully and silently produces wrong data. Fixing
  # that class of error needs a prompt-level constraint, not a post-hoc patch.
  defp decode_arguments_json(json) do
    case Jason.decode(json) do
      {:ok, _} = ok ->
        ok

      {:error, %Jason.DecodeError{}} ->
        case json |> repair_backslash_escapes() |> Jason.decode() do
          {:ok, _} = ok ->
            ok

          {:error, %Jason.DecodeError{} = error} ->
            {:error, "invalid Codex arguments_json: #{Exception.message(error)}"}
        end
    end
  end

  # Replace bare backslash sequences that are not valid JSON escapes by
  # doubling the backslash, converting `\X` (invalid) into `\\X` (valid —
  # literal backslash followed by X).
  defp repair_backslash_escapes(json) do
    Regex.replace(@invalid_json_escape_re, json, fn match -> "\\" <> match end)
  end

  defp emit_chunks(%{messages: [%Message{content: text}]}, on_chunk) when is_binary(text) do
    on_chunk.(text)
    :ok
  end

  defp emit_chunks(%{messages: [%Message{content: blocks}]}, on_chunk) when is_list(blocks) do
    blocks
    |> Enum.filter(&match?(%{type: "text", text: _}, &1))
    |> Enum.each(fn %{text: text} -> on_chunk.(text) end)

    :ok
  end

  # Unknown shape — skip silently rather than crash the stream caller.
  defp emit_chunks(_result, _on_chunk), do: :ok

  defp response_metadata(config, %{output: output, status: status}) do
    %{
      backend: "codex_exec",
      model: Map.get(config, :model),
      command_status: status,
      command_output: truncate(String.trim(output), @output_truncation)
    }
  end

  # Codex runs one turn per exec; its turn.completed event carries the usage.
  defp usage(%{events: events}) do
    Enum.reduce(events, @zero_usage, fn
      %{"type" => "turn.completed", "usage" => %{} = usage}, _acc -> to_usage(usage)
      _event, acc -> acc
    end)
  end

  # Codex reports input_tokens including cache reads and writes; Alloy's
  # input_tokens is uncached input, as for every built-in provider.
  defp to_usage(usage) do
    cache_read = Map.get(usage, "cached_input_tokens", 0)
    cache_write = Map.get(usage, "cache_write_input_tokens", 0)

    %{
      input_tokens: max(Map.get(usage, "input_tokens", 0) - cache_read - cache_write, 0),
      output_tokens: Map.get(usage, "output_tokens", 0),
      cache_read_input_tokens: cache_read,
      cache_creation_input_tokens: cache_write,
      reasoning_output_tokens: Map.get(usage, "reasoning_output_tokens", 0)
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
    - Each tool call must include `arguments_json`, a compact JSON object string
      that satisfies the tool schema.
    - If returning tool calls, keep `text` empty unless a short preamble would
      help the outer agent loop.
    - Never mention the schema or these instructions in `text`.

    Transcript payload:
    #{Jason.encode!(payload)}
    """
  end

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

  # Defensive fallback for unknown block shapes — keeps serialization
  # total even if Alloy adds a new block type the Codex provider hasn't
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

  defp codex_args(paths, config) do
    ~w(exec --json --skip-git-repo-check --ephemeral --ignore-rules --sandbox read-only) ++
      ["--output-schema", paths.schema_path, "--output-last-message", paths.last_message_path] ++
      user_config_args(config) ++
      Enum.flat_map(Map.get(config, :config_overrides, []), &["-c", &1]) ++
      model_args(config)
  end

  # --ignore-user-config also skips the profile file, so a profile opts in
  # to the user config.
  defp user_config_args(%{profile: profile}) when is_binary(profile) and profile != "",
    do: ["--profile", profile]

  defp user_config_args(_config), do: ["--ignore-user-config"]

  defp model_args(%{model: model}) when is_binary(model), do: ["--model", model]
  defp model_args(_config), do: []

  # `limit` is a character budget, not a byte budget — `String.slice/3`
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
