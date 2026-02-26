defmodule Mix.Tasks.Alloy do
  use Mix.Task

  @shortdoc "Run the Alloy agent interactively (or one-shot with -p)"

  @moduledoc """
  Run the Alloy agent harness from the terminal.

  By default, starts an **interactive REPL** that preserves conversation
  history between messages. Use `-p` for one-shot programmatic output.

  ## Interactive mode (default)

      mix alloy
      mix alloy --provider gemini --tools read,bash
      mix alloy "Start with this question"   # sends first message, then prompts

  ## Programmatic mode (-p)

      mix alloy -p "What is the capital of France?"
      mix alloy -p "Read mix.exs and tell me the version" --tools read
      mix alloy -p "Write a haiku" --provider openai --model gpt-5.2

  ## Options

      --provider   anthropic | gemini | google | openai   (default: anthropic)
      --model      Any valid model ID for the provider     (default: provider's best)
      --tools      Comma-separated: read,write,edit,bash   (default: all four)
      --system     System prompt string                    (default: none)
      --max-turns  Max agent loop iterations               (default: 25)
      --dir        Working directory for file tools        (default: .)
      --no-stream  Disable streaming (print full response at once)
      -p           Programmatic / one-shot mode

  ## Environment Variables

      ANTHROPIC_API_KEY   Required for --provider anthropic
      GEMINI_API_KEY      Required for --provider gemini/google
      OPENAI_API_KEY      Required for --provider openai
  """

  # ── Module Attributes ───────────────────────────────────────────────────

  @providers %{
    "anthropic" => {Alloy.Provider.Anthropic, "ANTHROPIC_API_KEY", "claude-opus-4-6"},
    "gemini" => {Alloy.Provider.Google, "GEMINI_API_KEY", "gemini-2.5-flash"},
    "google" => {Alloy.Provider.Google, "GEMINI_API_KEY", "gemini-2.5-flash"},
    "openai" => {Alloy.Provider.OpenAI, "OPENAI_API_KEY", "gpt-5.2"}
  }

  @tool_map %{
    "read" => Alloy.Tool.Core.Read,
    "write" => Alloy.Tool.Core.Write,
    "edit" => Alloy.Tool.Core.Edit,
    "bash" => Alloy.Tool.Core.Bash
  }

  @impl Mix.Task
  def run(argv) do
    Application.ensure_all_started(:req)

    {opts, words, _} =
      OptionParser.parse(argv,
        strict: [
          provider: :string,
          model: :string,
          tools: :string,
          system: :string,
          max_turns: :integer,
          dir: :string,
          programmatic: :boolean,
          no_context: :boolean,
          no_stream: :boolean
        ],
        aliases: [p: :programmatic, m: :model, t: :tools, s: :system]
      )

    opening_message = Enum.join(words, " ")
    programmatic? = Keyword.get(opts, :programmatic, false)

    provider_name = Keyword.get(opts, :provider, "anthropic")
    {provider_mod, api_key, default_model} = resolve_provider!(provider_name)
    model = Keyword.get(opts, :model, default_model)
    tools = parse_tools(Keyword.get(opts, :tools, "read,write,edit,bash"))
    working_dir = Keyword.get(opts, :dir, ".")
    system_prompt = Keyword.get(opts, :system)
    max_turns = Keyword.get(opts, :max_turns, 25)

    context_discovery = !Keyword.get(opts, :no_context, false)
    streaming? = !Keyword.get(opts, :no_stream, false)

    agent_opts = [
      provider: {provider_mod, api_key: api_key, model: model},
      tools: tools,
      system_prompt: system_prompt,
      max_turns: max_turns,
      working_directory: working_dir,
      context_discovery: context_discovery,
      streaming: streaming?
    ]

    if programmatic? do
      run_programmatic(opening_message, agent_opts, provider_name, model, tools)
    else
      run_interactive(opening_message, agent_opts, provider_name, model, tools)
    end
  end

  # ── Programmatic (one-shot) ────────────────────────────────────────────────

  defp run_programmatic("", _agent_opts, _provider, _model, _tools) do
    Mix.shell().error("""
    Usage: mix alloy -p "your message" [--provider anthropic|gemini|openai] [--tools read,bash]

    Run `mix help alloy` for full documentation.
    """)

    exit({:shutdown, 1})
  end

  defp run_programmatic(message, agent_opts, provider_name, model, tools) do
    Mix.shell().info("[alloy] #{provider_name}/#{model}" <> tool_label(tools))
    Mix.shell().info("")

    case Alloy.run(message, agent_opts) do
      {:ok, result} ->
        Mix.shell().info(result.text || "(no text response)")
        Mix.shell().info("")
        Mix.shell().info(footer(result))

      {:error, result} ->
        Mix.shell().error("Agent error: #{inspect(result.error)}")
        exit({:shutdown, 1})
    end
  end

  # ── Interactive (REPL) ────────────────────────────────────────────────────

  defp run_interactive(opening_message, agent_opts, provider_name, model, tools) do
    Mix.shell().info("[alloy] #{provider_name}/#{model}" <> tool_label(tools) <> " · interactive")

    skills = Alloy.Skill.discover()

    if skills != [] do
      skill_names = Enum.map_join(skills, ", ", &"/#{&1.name}")
      Mix.shell().info("Skills: #{skill_names}")
    end

    Mix.shell().info("Type 'exit' or Ctrl+C to quit.\n")

    {:ok, pid} = Alloy.Agent.Server.start_link(agent_opts)

    if opening_message != "" do
      chat_and_print(pid, opening_message)
    end

    repl_loop(pid, skills)
  end

  defp repl_loop(pid, skills) do
    case IO.gets("You: ") do
      :eof ->
        Mix.shell().info("\nGoodbye!")

      {:error, _} ->
        Mix.shell().info("\nGoodbye!")

      input ->
        message = String.trim(input)

        cond do
          message in ["exit", "quit", "bye", "q"] ->
            Mix.shell().info("Goodbye!")

          message == "" ->
            repl_loop(pid, skills)

          # ── Built-in REPL commands (before skill handler) ──────────
          message == "/help" ->
            handle_help(skills)
            repl_loop(pid, skills)

          message == "/usage" ->
            handle_usage(pid)
            repl_loop(pid, skills)

          message == "/history" ->
            handle_history(pid)
            repl_loop(pid, skills)

          message == "/reset" ->
            handle_reset(pid)
            repl_loop(pid, skills)

          String.starts_with?(message, "/model") ->
            handle_model_command(pid, message)
            repl_loop(pid, skills)

          # ── Skill commands ─────────────────────────────────────────
          String.starts_with?(message, "/") ->
            handle_skill_command(pid, message, skills)
            repl_loop(pid, skills)

          true ->
            chat_and_print(pid, message)
            repl_loop(pid, skills)
        end
    end
  end

  defp handle_skill_command(pid, message, skills) do
    [command | rest] = String.split(message, " ", parts: 2)
    skill_name = String.trim_leading(command, "/")
    input = List.first(rest, "")

    case Enum.find(skills, &(&1.name == skill_name)) do
      nil ->
        Mix.shell().error("Unknown skill: /#{skill_name}")

        if skills != [] do
          names = Enum.map_join(skills, ", ", &"/#{&1.name}")
          Mix.shell().info("Available skills: #{names}")
        end

      skill ->
        expanded = Alloy.Skill.apply(skill, input)
        chat_and_print(pid, expanded)
    end
  end

  # ── Built-in REPL Command Handlers ──────────────────────────────────────

  defp handle_help(skills) do
    Mix.shell().info("""

    Built-in commands:
      /help     Show this help message
      /model    Show current provider and model
      /model <provider>[/<model>]  Switch provider (and optionally model)
      /usage    Show accumulated token usage
      /history  Show condensed conversation history
      /reset    Clear conversation history
      exit      Quit the REPL
    """)

    if skills != [] do
      names = Enum.map_join(skills, ", ", &"/#{&1.name}")
      Mix.shell().info("Skills: #{names}\n")
    end
  end

  defp handle_usage(pid) do
    usage = Alloy.Agent.Server.usage(pid)

    Mix.shell().info("""

    Token usage:
      Input tokens:  #{usage.input_tokens}
      Output tokens: #{usage.output_tokens}
      Cache creation: #{usage.cache_creation_input_tokens}
      Cache read:    #{usage.cache_read_input_tokens}
      Total:         #{Alloy.Usage.total(usage)}
    """)
  end

  defp handle_history(pid) do
    messages = Alloy.Agent.Server.messages(pid)

    if messages == [] do
      Mix.shell().info("\n(no messages yet)\n")
    else
      Mix.shell().info("")

      Enum.each(messages, fn msg ->
        line = format_history_line(msg)
        Mix.shell().info(line)
      end)

      Mix.shell().info("")
    end
  end

  defp format_history_line(%Alloy.Message{role: role, content: content})
       when is_binary(content) do
    truncated = String.slice(content, 0, 80)
    suffix = if String.length(content) > 80, do: "...", else: ""
    "  #{role}: #{truncated}#{suffix}"
  end

  defp format_history_line(%Alloy.Message{role: role, content: blocks})
       when is_list(blocks) do
    parts =
      Enum.map(blocks, fn
        %{type: "text", text: text} ->
          truncated = String.slice(text, 0, 80)
          suffix = if String.length(text) > 80, do: "...", else: ""
          truncated <> suffix

        %{type: "tool_use", name: name} ->
          "[tool_use: #{name}]"

        %{type: "tool_result"} ->
          "[tool_result]"

        _other ->
          "[...]"
      end)

    "  #{role}: #{Enum.join(parts, " ")}"
  end

  defp handle_reset(pid) do
    :ok = Alloy.Agent.Server.reset(pid)
    Mix.shell().info("\nConversation history cleared.\n")
  end

  defp handle_model_command(pid, message) do
    args =
      message
      |> String.trim_leading("/model")
      |> String.trim()

    if args == "" do
      # Show current model
      state = :sys.get_state(pid)
      provider_name = provider_display_name(state.config.provider)
      model = Map.get(state.config.provider_config, :model, "(default)")
      Mix.shell().info("\nCurrent: #{provider_name}/#{model}\n")
    else
      # Switch model: args can be "provider" or "provider/model"
      {provider_name, model_override} =
        case String.split(args, "/", parts: 2) do
          [p, m] -> {p, m}
          [p] -> {p, nil}
        end

      case Map.get(@providers, provider_name) do
        nil ->
          available = @providers |> Map.keys() |> Enum.join(", ")
          Mix.shell().error("Unknown provider: #{provider_name}\nAvailable: #{available}")

        {mod, env_var, default_model} ->
          api_key = System.get_env(env_var)

          if api_key do
            model = model_override || default_model

            :ok =
              Alloy.Agent.Server.set_model(pid,
                provider: {mod, api_key: api_key, model: model}
              )

            Mix.shell().info("\nSwitched to #{provider_name}/#{model}\n")
          else
            Mix.shell().error("#{env_var} is not set. Cannot switch to #{provider_name}.")
          end
      end
    end
  end

  defp provider_display_name(mod) do
    # Reverse-lookup the provider name from the module
    case Enum.find(@providers, fn {_name, {m, _env, _model}} -> m == mod end) do
      {name, _} -> name
      nil -> inspect(mod)
    end
  end

  defp chat_and_print(pid, message) do
    # Check if the agent's config has streaming enabled
    state = :sys.get_state(pid)
    streaming? = state.config.streaming

    if streaming? do
      IO.write("\nAlloy: ")

      on_chunk = fn chunk -> IO.write(chunk) end

      case Alloy.Agent.Server.stream_chat(pid, message, on_chunk) do
        {:ok, result} ->
          IO.write("\n")
          tokens = result.usage.input_tokens + result.usage.output_tokens

          Mix.shell().info(
            "  [#{result.turns} turn#{if result.turns == 1, do: "", else: "s"} | #{tokens} tokens]\n"
          )

        {:error, result} ->
          IO.write("\n")
          Mix.shell().error("Error: #{inspect(result.error)}")
      end
    else
      case Alloy.Agent.Server.chat(pid, message) do
        {:ok, result} ->
          Mix.shell().info("\nAlloy: #{result.text || "(no text response)"}")
          tokens = result.usage.input_tokens + result.usage.output_tokens

          Mix.shell().info(
            "  [#{result.turns} turn#{if result.turns == 1, do: "", else: "s"} | #{tokens} tokens]\n"
          )

        {:error, result} ->
          Mix.shell().error("Error: #{inspect(result.error)}")
      end
    end
  end

  # ── Providers ─────────────────────────────────────────────────────────────

  defp resolve_provider!(name) do
    case Map.get(@providers, name) do
      nil ->
        Mix.shell().error(
          "Unknown provider: #{name}\nAvailable: #{Map.keys(@providers) |> Enum.join(", ")}"
        )

        exit({:shutdown, 1})

      {mod, env_var, default_model} ->
        api_key =
          System.get_env(env_var) ||
            Mix.raise("#{env_var} is not set. Export it in your shell or .env file.")

        {mod, api_key, default_model}
    end
  end

  # ── Tools ─────────────────────────────────────────────────────────────────

  defp parse_tools(""), do: []

  defp parse_tools(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn name ->
      Map.get(@tool_map, name) ||
        Mix.raise("Unknown tool: #{name}\nAvailable: #{Map.keys(@tool_map) |> Enum.join(", ")}")
    end)
  end

  # ── Formatting ────────────────────────────────────────────────────────────

  defp tool_label([]), do: ""
  defp tool_label(tools), do: " +[#{tools |> Enum.map(& &1.name()) |> Enum.join(",")}]"

  defp footer(result) do
    tokens = result.usage.input_tokens + result.usage.output_tokens
    "[#{result.turns} turn#{if result.turns == 1, do: "", else: "s"} | #{tokens} tokens]"
  end
end
