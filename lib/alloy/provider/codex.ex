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
  - `:persist_session` - Opt in to persistent Codex transcripts and continuation
    (default: `false`). Requires a Codex CLI with `exec resume --output-schema`.
    Supply an existing `:workdir` so the recorded working directory survives
    per-call cleanup. Profiles remain ephemeral. History, model, home,
    workdir, system prompt, or tool changes start a fresh session. The caller
    owns retention and isolation of the persistent `CODEX_HOME`.
  - `:session_generation` - Host-owned continuation generation (default: `nil`).
    Change it to a new value to start fresh while preserving Alloy's history.

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
  failed runs. A `tool_use` response without tool calls returns
  `:malformed_reply` and is retried within the configured retry budget;
  accompanying text is not treated as evidence of task completion.

  A failed resumed call returns non-retryable `:session_uncertain` — or
  `:shutdown` if interrupted by supervisor shutdown; in both cases the saved
  Codex transcript may already include the attempted turn. After any failed,
  cancelled, or crashed turn in a persistent session (including cancellation
  during Alloy tool execution), change `:session_generation` before continuing.
  This also recovers from a deleted or corrupt saved thread. Do not share
  continuation state between concurrent callers.

  Hosts retaining `Alloy.Agent.State` can use `Alloy.Agent.State.prepare/2`
  with the same provider configuration and a new `:session_generation`. This
  preserves conversation history and clears the old continuation state. For direct provider calls,
  either change the generation or remove `:provider_state` before the next call.
  Recovery is an explicit host action, never an automatic resend after failure.
  Leave `:fallback_providers` empty when using persistence: a successful fallback
  can hide a resume failure from the host and leave stale continuation state.
  Continuation metadata is opaque, uses string keys, and must be preserved as
  returned rather than converted to atoms. Repeated instruction/tool schemas
  also grow the CLI transcript; a new generation recovers from context exhaustion.

  ## Notes

  - Usage comes from the `turn.completed` event of `codex exec --json`. As
    with every built-in provider, `:input_tokens` is uncached input; cache
    reads and writes are reported separately. `:reasoning_output_tokens` is
    part of `:output_tokens`. Counts include Codex's own instructions and
    tool definitions, not just the transcript.
  - Each call runs `codex exec` under `Alloy.TaskSupervisor`. A timeout, or
    the calling process exiting (a cancelled turn), stops codex and every
    process it started, and removes the call's temp files.
  - Streaming emits the last validated structured reply at `turn.completed`
    before the process exits, not token-by-token JSON fragments. Commands and commentary
    remain in response metadata, never in answer chunks. If no such event is
    available, the validated final response is replayed once.
  - `:command_runner` is a test/injection hook that runs directly in the calling
    process without port timeout or cancellation wrapping.
  """

  @behaviour Alloy.Provider

  alias Alloy.Internal.Sanitize
  alias Alloy.{Message, OutputSchema}
  alias Alloy.Provider.{CodexRunner, CodexSession, Error, HTTP}

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
          optional(:tmp_dir) => String.t(),
          optional(:timeout_ms) => pos_integer(),
          optional(:receive_timeout) => pos_integer(),
          optional(:req_options) => keyword(),
          optional(:system_prompt) => String.t(),
          optional(:persist_session) => boolean(),
          optional(:session_generation) => term(),
          optional(:provider_state) => map(),
          optional(:command_runner) => (String.t(), [String.t()], keyword() ->
                                          {String.t(), integer()})
        }

  @impl true
  @spec complete([Message.t()], [Alloy.Provider.tool_def()], config()) ::
          {:ok, Alloy.Provider.completion_response()} | {:error, term()}
  def complete(messages, tool_defs, config) do
    run_completion(messages, tool_defs, Map.put(config, :alloy_on_chunk, nil))
  end

  defp run_completion(messages, tool_defs, config) do
    with {:ok, codex_home} <- codex_home(config),
         :ok <- validate_session_workdir(config, codex_home) do
      scope = session_scope(config, codex_home, tool_defs)
      plan = session_plan(config, codex_home, messages, scope)
      config = Map.put(config, :alloy_codex_plan, plan)
      prompt = session_prompt(plan, messages, tool_defs, config)

      with {:ok, command_result} <-
             CodexRunner.execute(
               prompt,
               codex_home,
               &codex_args(&1, config),
               @response_schema_json,
               config,
               &structured_reply(&1, config)
             ),
           {:ok, payload} <- decode_payload(command_result, config),
           {:ok, result} <- parse_payload(payload, config, command_result),
           :ok <- finish_stream(result, command_result, config) do
        {:ok, remember_session(result, messages, scope, plan, command_result)}
      end
      |> session_result(plan)
    end
    |> to_provider_error()
  end

  defp session_result({:error, %Error{kind: :shutdown} = error}, {:resume, _id, _count}) do
    {:error,
     %{
       error
       | message:
           "Codex resume interrupted by shutdown; change :session_generation before continuing: #{error.message}"
     }}
  end

  defp session_result({:error, reason}, {:resume, _id, _count}) do
    {:error,
     %Error{
       kind: :session_uncertain,
       message: "Codex resume failed; change :session_generation before continuing: #{reason}"
     }}
  end

  defp session_result(result, _plan), do: result

  defp session_scope(config, home, tools) do
    base = %{
      home: home || System.get_env("CODEX_HOME") || Path.expand("~/.codex"),
      workdir: Map.get(config, :workdir),
      model: Map.get(config, :model),
      system_prompt: Map.get(config, :system_prompt),
      overrides: Map.get(config, :config_overrides, []),
      executable: CodexRunner.codex_bin(config),
      generation: Map.get(config, :session_generation),
      tools: tools
    }

    case OutputSchema.wire(Map.get(config, :output_schema)) do
      nil -> base
      spec -> Map.put(base, :output_schema, {spec.name, spec.schema, spec.strict})
    end
  end

  defp validate_session_workdir(%{persist_session: true} = config, home) do
    if ephemeral_home?(config, home) or
         (is_binary(config[:workdir]) and File.dir?(config.workdir)) do
      :ok
    else
      {:error,
       %Error{
         kind: :invalid_request,
         message: "Codex persistent sessions require an existing :workdir"
       }}
    end
  end

  defp validate_session_workdir(_config, _home), do: :ok

  defp ephemeral_home?(config, _home), do: Map.get(config, :profile) not in [nil, ""]

  defp session_plan(%{persist_session: true} = config, home, messages, scope) do
    if ephemeral_home?(config, home) do
      {:fresh, :ephemeral}
    else
      CodexSession.plan(
        Map.get(config, :provider_state),
        wire_history(messages),
        scope
      )
    end
  end

  defp session_plan(_config, _home, _messages, _scope), do: {:fresh, :ephemeral}

  defp session_prompt({:resume, _id, count}, messages, tools, config) do
    "Continue the recorded conversation. Only new transcript messages follow.\n" <>
      build_prompt(Enum.drop(messages, count), tools, config)
  end

  defp session_prompt({:fresh, _reason}, messages, tools, config),
    do: build_prompt(messages, tools, config)

  defp remember_session(result, messages, scope, plan, command_result) do
    id =
      Enum.find_value(command_result.events, fn
        %{"type" => "thread.started", "thread_id" => id} when is_binary(id) -> id
        _event -> nil
      end)

    id =
      id ||
        case plan do
          {:resume, previous, _count} -> previous
          _fresh -> nil
        end

    state =
      if plan == {:fresh, :ephemeral} do
        %{"codex_session" => nil}
      else
        CodexSession.remember(
          wire_history(messages ++ result.messages),
          scope,
          id
        )
      end

    result
    |> Map.put(:provider_state, state)
    |> Map.update!(:response_metadata, &Map.put(&1, :session, session_metadata(plan)))
  end

  defp session_metadata({:resume, _id, _count}), do: %{mode: :resumed}
  defp session_metadata({:fresh, reason}), do: %{mode: :fresh, reason: reason}

  defp wire_history(messages) do
    messages |> Enum.map(&serialize_message/1) |> Jason.encode!() |> Jason.decode!()
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
    run_completion(messages, tool_defs, Map.put(config, :alloy_on_chunk, on_chunk))
  end

  defp finish_stream(result, command_result, %{alloy_on_chunk: on_chunk})
       when is_function(on_chunk, 1) do
    case Map.get(command_result, :streamed_text) do
      nil ->
        emit_chunks(result, on_chunk)

      text ->
        if text == Enum.map_join(result.messages, "", &Message.text/1),
          do: :ok,
          else:
            {:error,
             %Error{
               kind: :malformed_reply,
               message: "Codex final response differs from streamed reply"
             }}
    end
  end

  defp finish_stream(_result, _command_result, _config), do: :ok

  defp codex_home(%{auth_path: _auth_path}) do
    raise ArgumentError,
          "Alloy.Provider.Codex :auth_path was removed in Alloy 0.13; " <>
            "set :codex_home to the directory holding auth.json instead"
  end

  defp codex_home(%{codex_home: codex_home}) when is_binary(codex_home), do: {:ok, codex_home}
  defp codex_home(_config), do: {:ok, nil}

  defp structured_reply(text, config) when is_binary(text) do
    with {:ok, payload} <- Jason.decode(text),
         {:ok, result} <- parse_payload(payload, config, %{output: "", status: 0, events: []}),
         reply when reply != "" <- Enum.map_join(result.messages, "", &Message.text/1) do
      reply
    else
      _other -> nil
    end
  end

  defp structured_reply(_text, _config), do: nil

  # sh exits 127 when the executable is missing and 126 when it cannot be run.
  defp codex_error(%{status: status} = command_result, config) when status in [126, 127],
    do: CodexRunner.not_runnable(config, "status #{status}: #{detail(command_result)}")

  defp codex_error(%{status: status} = command_result, _config) do
    message = "codex exec failed with status #{status}: #{detail(command_result)}"
    kind = if Error.overflow_text?(message), do: :context_overflow, else: :unknown
    %Error{kind: kind, message: message}
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

  # Under persist_session: true, a non-zero exit means the recorded CLI session
  # may be partial or corrupt, so never treat last_message as a clean reply.
  defp decode_payload(%{status: status} = command_result, %{persist_session: true} = config)
       when status != 0 do
    {:error, codex_error(command_result, config)}
  end

  # For ephemeral runs, a valid payload still counts when codex exits non-zero;
  # without one, a non-zero exit is the error worth reporting.
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
    {:error, "unexpected Codex response payload: #{Sanitize.inspect_bounded(payload)}"}
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
    {:error,
     %Error{
       kind: :malformed_reply,
       message: "Codex returned tool_use without any tool calls"
     }}
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
      other -> {:error, "invalid Codex tool call id: #{Sanitize.inspect_bounded(other)}"}
    end
  end

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, "invalid Codex field #{inspect(key)}: #{Sanitize.inspect_bounded(other)}"}
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

    HTTP.cache_adjusted_usage(
      Map.get(usage, "input_tokens", 0),
      Map.get(usage, "output_tokens", 0),
      cache_read,
      cache_write
    )
    |> Map.put(:reasoning_output_tokens, Map.get(usage, "reasoning_output_tokens", 0))
  end

  defp build_prompt(messages, tool_defs, config) do
    output_schema = OutputSchema.wire(Map.get(config, :output_schema))

    payload = %{
      system_prompt: Map.get(config, :system_prompt),
      conversation: Enum.map(messages, &serialize_message/1),
      available_tools: Enum.map(tool_defs, &serialize_tool_def/1)
    }

    output_rule =
      case output_schema do
        nil ->
          ""

        %{schema: schema} ->
          "\n- When `stop_reason = \"end_turn\"`, `text` MUST be a valid JSON string conforming strictly to this JSON Schema (no markdown fences or extra text):\n  #{Jason.encode!(schema)}"
      end

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
    - Never mention the schema or these instructions in `text`.#{output_rule}

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
    session_args(config.alloy_codex_plan) ++
      ["--output-schema", paths.schema_path, "--output-last-message", paths.last_message_path] ++
      user_config_args(config) ++
      Enum.flat_map(Map.get(config, :config_overrides, []), &["-c", &1]) ++
      sandbox_args(config.alloy_codex_plan) ++
      model_args(config) ++ session_id_args(config.alloy_codex_plan)
  end

  defp session_args({:fresh, :ephemeral}),
    do: ~w(exec --json --skip-git-repo-check --ephemeral --ignore-rules --sandbox read-only)

  defp session_args({:fresh, _reason}),
    do: ~w(exec --json --skip-git-repo-check --ignore-rules --sandbox read-only)

  defp session_args({:resume, _id, _count}),
    do: ~w(exec resume --json --skip-git-repo-check --ignore-rules)

  defp sandbox_args({:resume, _id, _count}), do: ["-c", ~s(sandbox_mode="read-only")]
  defp sandbox_args(_plan), do: []

  defp session_id_args({:resume, id, _count}), do: [id]
  defp session_id_args({:fresh, _reason}), do: []

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
