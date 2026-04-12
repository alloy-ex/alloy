defmodule Alloy.Provider.CodexTest do
  use ExUnit.Case, async: true

  alias Alloy.Message
  alias Alloy.Provider.Codex

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
      assert reason =~ "tool_calls"
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
      assert reason =~ "arguments_json"
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

    test "passes the prompt via stdin for the real shell-backed runner" do
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "alloy-codex-provider-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(temp_dir)
      on_exit(fn -> File.rm_rf(temp_dir) end)

      auth_path = Path.join(temp_dir, "auth.json")
      File.write!(auth_path, "{}")

      script_path = Path.join(temp_dir, "fake-codex.sh")

      File.write!(
        script_path,
        """
        #!/bin/sh
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

        prompt="$(cat)"

        case "$prompt" in
          *"Need a decision"*) ;;
          *)
            echo "missing prompt on stdin" >&2
            exit 42
            ;;
        esac

        printf '%s' '{"stop_reason":"end_turn","text":"stdin ok","tool_calls":[]}' > "$output"
        printf '%s\\n' '{"event":"done"}'
        """
      )

      File.chmod!(script_path, 0o755)

      config = %{
        model: "gpt-5.4",
        codex_bin: script_path,
        auth_path: auth_path
      }

      assert {:ok, result} = Codex.complete([Message.user("Need a decision")], [], config)
      assert result.messages == [Message.assistant("stdin ok")]
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
end
