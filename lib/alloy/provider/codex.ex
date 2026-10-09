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
  - `:auth_path` - Deprecated, use `:codex_home`. A path to an `auth.json`
    file; its directory is used as `CODEX_HOME`.
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

  ## Notes

  - Usage accounting is not exposed by `codex exec` in a structured form yet,
    so this provider currently reports zero token counts.
  - Streaming is emulated by running a normal completion and replaying the final
    text to the provided callback.
  """

  @behaviour Alloy.Provider

  alias Alloy.Message

  @default_timeout_ms 120_000
  @default_codex_bin "codex"
  @output_truncation 4_000
  @error_truncation 2_000
  @zero_usage %{input_tokens: 0, output_tokens: 0}

  # Matches any `\X` where X is NOT a valid JSON single-character escape
  # (valid set: " \ / b f n r t u). Used by the decode repair pass.
  @invalid_json_escape_re ~r{\\(?!["\\/bfnrtu])}

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
          optional(:auth_path) => String.t(),
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
    with {:ok, codex_home} <- codex_home(config),
         {:ok, paths} <- prepare_paths(codex_home, config) do
      try do
        with :ok <- File.write(paths.schema_path, @response_schema_json),
             prompt = build_prompt(messages, tool_defs, config),
             :ok <- File.write(paths.prompt_path, prompt),
             {:ok, command_result} <- run_codex(prompt, paths, config),
             {:ok, payload} <- read_payload_or_error(paths.last_message_path, command_result) do
          parse_payload(payload, config, command_result)
        end
      after
        cleanup_paths(paths)
      end
    end
  end

  @impl true
  @spec stream([Message.t()], [Alloy.Provider.tool_def()], config(), (String.t() -> :ok)) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def stream(messages, tool_defs, config, on_chunk) when is_function(on_chunk, 1) do
    with {:ok, result} <- complete(messages, tool_defs, config),
         :ok <- emit_chunks(result, on_chunk) do
      {:ok, result}
    end
  end

  defp codex_home(%{codex_home: codex_home}) when is_binary(codex_home), do: {:ok, codex_home}

  defp codex_home(%{auth_path: auth_path}) when is_binary(auth_path) do
    case Path.basename(auth_path) do
      "auth.json" ->
        {:ok, Path.dirname(auth_path)}

      _other ->
        {:error,
         "Codex reads auth.json from CODEX_HOME, so :auth_path must name an auth.json file " <>
           "(got #{inspect(auth_path)}); set :codex_home to its directory instead"}
    end
  end

  defp codex_home(_config), do: {:ok, nil}

  defp prepare_paths(codex_home, config) do
    base_dir = build_base_dir(config)

    case File.mkdir_p(base_dir) do
      :ok -> {:ok, build_paths(base_dir, codex_home, config)}
      {:error, reason} -> {:error, "failed to prepare Codex temp directory: #{inspect(reason)}"}
    end
  end

  defp build_base_dir(config) do
    parent = Map.get(config, :tmp_dir) || System.tmp_dir!()
    Path.join(parent, "alloy-codex-#{System.unique_integer([:positive])}")
  end

  defp build_paths(base_dir, codex_home, config) do
    %{
      base_dir: base_dir,
      codex_home: codex_home,
      prompt_path: Path.join(base_dir, "prompt.txt"),
      schema_path: Path.join(base_dir, "response_schema.json"),
      last_message_path: Path.join(base_dir, "last_message.json"),
      workdir: Map.get(config, :workdir, base_dir)
    }
  end

  defp cleanup_paths(%{base_dir: base_dir}) do
    _ = File.rm_rf(base_dir)
    :ok
  end

  defp run_codex(prompt, paths, config) do
    executable = Map.get(config, :codex_bin, @default_codex_bin)
    timeout = effective_timeout(config)

    args =
      [
        "exec",
        "--skip-git-repo-check",
        "--ephemeral",
        "--ignore-rules",
        "--sandbox",
        "read-only",
        "--output-schema",
        paths.schema_path,
        "--output-last-message",
        paths.last_message_path
      ]
      |> append_user_config(config)
      |> append_config_overrides(config)
      |> maybe_append_model(config)
      |> append_prompt_arg(prompt, config)

    if injected_runner?(config) do
      run_injected(config, executable, args, paths)
    else
      run_port(executable, args, paths, timeout)
    end
  end

  defp effective_timeout(config) do
    [
      Map.get(config, :timeout_ms, @default_timeout_ms),
      Map.get(config, :receive_timeout),
      config |> Map.get(:req_options, []) |> Keyword.get(:receive_timeout)
    ]
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.min()
  end

  # Test path: the caller supplies a synchronous function matching
  # `System.cmd/3`. No timeout enforcement — tests should be fast enough
  # to rely on ExUnit's own timeout.
  defp run_injected(config, executable, args, paths) do
    runner = Map.fetch!(config, :command_runner)
    opts = [cd: paths.workdir, env: codex_env(paths), stderr_to_stdout: true]

    case runner.(executable, args, opts) do
      {output, status} when is_binary(output) and is_integer(status) ->
        {:ok, %{output: output, status: status}}

      other ->
        {:error, "codex exec returned unexpected result: #{inspect(other)}"}
    end
  rescue
    error in ErlangError ->
      {:error, "codex exec failed to start: #{Exception.message(error)}"}
  end

  # Real path: spawn via Port so we capture the OS pid and can kill the
  # subprocess on timeout. `exec env ... codex ...` makes the shell process
  # replace itself with env, which replaces itself with codex — so
  # `Port.info(:os_pid)` returns codex's own pid rather than a shell pid
  # whose children we'd otherwise orphan.
  defp run_port(executable, args, paths, timeout) do
    shell_command = build_port_command(executable, args, paths)
    deadline = System.monotonic_time(:millisecond) + timeout

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          {:args, ["-lc", shell_command]},
          {:cd, paths.workdir},
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout
        ]
      )

    # Port.info/2 returns nil when the process already exited — its output
    # and exit_status messages are still in the mailbox, so collect them;
    # there is just no OS pid left to kill on timeout.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> collect_port(port, os_pid, timeout, deadline, [])
      nil -> collect_port(port, nil, timeout, deadline, [])
    end
  rescue
    error in ErlangError ->
      {:error, "codex exec failed to start: #{Exception.message(error)}"}
  end

  defp build_port_command(executable, args, paths) do
    env_args =
      paths
      |> codex_env()
      |> Enum.map_join(" ", fn {key, value} -> shell_escape("#{key}=#{value}") end)

    "exec env " <>
      env_args <>
      " " <>
      Enum.map_join([executable | args], " ", &shell_escape/1) <>
      " < " <>
      shell_escape(paths.prompt_path)
  end

  defp codex_env(%{codex_home: nil}), do: [{"OTEL_SDK_DISABLED", "true"}]

  defp codex_env(%{codex_home: codex_home}),
    do: [{"OTEL_SDK_DISABLED", "true"}, {"CODEX_HOME", codex_home}]

  defp collect_port(port, os_pid, timeout, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      timeout_port(port, os_pid, timeout)
    else
      receive_port(port, os_pid, timeout, deadline, remaining, acc)
    end
  end

  defp receive_port(port, os_pid, timeout, deadline, remaining, acc) do
    receive do
      {^port, {:data, data}} when is_binary(data) ->
        collect_port(port, os_pid, timeout, deadline, [acc, data])

      {^port, {:exit_status, status}} ->
        {:ok, %{output: IO.iodata_to_binary(acc), status: status}}
    after
      remaining ->
        timeout_port(port, os_pid, timeout)
    end
  end

  defp timeout_port(port, os_pid, timeout) do
    _ = kill_os_process(os_pid)
    _ = close_and_drain(port)
    {:error, "codex exec timed out after #{timeout}ms"}
  end

  # SIGTERM with a 100ms grace window, then SIGKILL. Best-effort — if
  # codex has already exited, the second kill is a no-op.
  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) do
    _ = System.cmd("/bin/kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    Process.sleep(100)
    _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
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

  defp append_prompt_arg(args, prompt, config) do
    if injected_runner?(config) do
      args ++ [prompt]
    else
      args ++ ["-"]
    end
  end

  # An explicit `:command_runner` in config means the caller is driving
  # process execution themselves (almost always a test). Real usage goes
  # through the shell wrapper so we can inject env and stdin-feed the prompt.
  defp injected_runner?(config), do: Map.has_key?(config, :command_runner)

  defp codex_error(status, output) do
    message =
      output
      |> String.trim()
      |> truncate(@error_truncation)

    "codex exec failed with status #{status}: #{message}"
  end

  defp read_payload_or_error(path, %{status: status, output: output}) do
    case read_payload(path) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} when status == 0 ->
        {:error, reason}

      {:error, _reason} ->
        {:error, codex_error(status, output)}
    end
  end

  defp read_payload(path) do
    with {:ok, content} <- File.read(path),
         {:ok, payload} <- Jason.decode(content) do
      {:ok, payload}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "failed to read Codex response file: #{inspect(reason)}"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "failed to decode Codex response JSON: #{Exception.message(error)}"}
    end
  end

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
         usage: @zero_usage,
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
         usage: @zero_usage,
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

  # --ignore-user-config also skips the profile file, so a profile opts in
  # to the user config.
  defp append_user_config(args, %{profile: profile}) when is_binary(profile) and profile != "",
    do: args ++ ["--profile", profile]

  defp append_user_config(args, _config), do: args ++ ["--ignore-user-config"]

  defp append_config_overrides(args, config) do
    args ++ Enum.flat_map(Map.get(config, :config_overrides, []), &["-c", &1])
  end

  defp maybe_append_model(args, config) do
    case Map.get(config, :model) do
      nil -> args
      model -> args ++ ["--model", model]
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

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
