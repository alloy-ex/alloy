defmodule Alloy.Tool.InlineTest do
  use ExUnit.Case, async: true

  alias Alloy.Provider.Test, as: TestProvider
  alias Alloy.Tool.Registry

  defp weather_tool(opts \\ []) do
    Alloy.Tool.inline(
      Keyword.merge(
        [
          name: "get_weather",
          description: "Get current weather for a location",
          input_schema: %{
            type: "object",
            properties: %{location: %{type: "string"}},
            required: ["location"]
          },
          execute: fn %{"location" => loc}, _context -> {:ok, "22°C in #{loc}"} end
        ],
        opts
      )
    )
  end

  defp run_with_tool(tool, responses) do
    {:ok, pid} = TestProvider.start_link(responses)

    Alloy.run("What's the weather in Sydney?",
      provider: {TestProvider, agent_pid: pid},
      tools: [tool]
    )
  end

  defp weather_call do
    TestProvider.tool_use_response([
      %{
        type: "tool_use",
        id: "call_1",
        name: "get_weather",
        input: %{"location" => "Sydney"}
      }
    ])
  end

  describe "Alloy.Tool.inline/1" do
    test "builds a validated struct" do
      tool = weather_tool()
      assert %Alloy.Tool.Inline{name: "get_weather", concurrent?: true} = tool
    end

    test "rejects missing required fields" do
      assert_raise ArgumentError, fn ->
        Alloy.Tool.inline(name: "x", description: "y")
      end
    end

    test "rejects a non-2-arity execute function" do
      assert_raise ArgumentError, ~r/2-arity/, fn ->
        weather_tool(execute: fn _input -> {:ok, "nope"} end)
      end
    end

    test "rejects empty names" do
      assert_raise ArgumentError, ~r/non-empty string/, fn ->
        weather_tool(name: "")
      end
    end

    test "rejects unknown options" do
      assert_raise ArgumentError, ~r/unknown inline tool option/, fn ->
        weather_tool(timeout: 5_000)
      end
    end
  end

  describe "Registry with inline tools" do
    test "builds defs and dispatch map from mixed module and inline tools" do
      {defs, fns} = Registry.build([weather_tool(), Alloy.Tool.Core.Read])

      assert [%{name: "get_weather"}, %{name: "read"}] = defs
      assert %Alloy.Tool.Inline{} = fns["get_weather"]
      assert fns["read"] == Alloy.Tool.Core.Read
    end

    test "inline optional fields appear in defs only when set" do
      {[def_without], _} = Registry.build([weather_tool()])
      refute Map.has_key?(def_without, :allowed_callers)
      refute Map.has_key?(def_without, :result_type)

      {[def_with], _} =
        Registry.build([
          weather_tool(allowed_callers: [:human], result_type: :structured)
        ])

      assert def_with.allowed_callers == [:human]
      assert def_with.result_type == :structured
    end

    test "rejects things that are neither modules nor inline tools" do
      assert_raise ArgumentError, ~r/tools must be modules/, fn ->
        Registry.build([%{name: "not", a: "tool"}])
      end
    end
  end

  describe "inline tools in the agent loop" do
    test "executes an inline tool end to end" do
      {:ok, result} =
        run_with_tool(weather_tool(), [
          weather_call(),
          TestProvider.text_response("It's 22°C in Sydney.")
        ])

      assert result.status == :completed
      assert result.text == "It's 22°C in Sydney."
      assert [%{name: "get_weather", error: nil}] = result.tool_calls
    end

    test "inline tool errors flow back as tool errors" do
      failing =
        weather_tool(execute: fn _input, _context -> {:error, "service down"} end)

      {:ok, result} =
        run_with_tool(failing, [
          weather_call(),
          TestProvider.text_response("Couldn't get the weather.")
        ])

      assert result.status == :completed
      assert [%{name: "get_weather", error: "service down"}] = result.tool_calls
    end

    test "inline tool exceptions are caught like module tool crashes" do
      crashing =
        weather_tool(execute: fn _input, _context -> raise "boom" end)

      {:ok, result} =
        run_with_tool(crashing, [
          weather_call(),
          TestProvider.text_response("Tool crashed.")
        ])

      assert [%{name: "get_weather", error: "Tool crashed: boom"}] = result.tool_calls
    end

    test "structured 3-tuple results carry structured data" do
      structured =
        weather_tool(
          result_type: :structured,
          execute: fn %{"location" => loc}, _context ->
            {:ok, "22°C in #{loc}", %{temp_c: 22, location: loc}}
          end
        )

      {:ok, result} =
        run_with_tool(structured, [
          weather_call(),
          TestProvider.text_response("Done.")
        ])

      assert [%{structured_data: %{temp_c: 22}}] = result.tool_calls
    end

    test "max_result_chars truncates inline tool output" do
      verbose =
        weather_tool(
          max_result_chars: 100,
          execute: fn _input, _context -> {:ok, String.duplicate("x", 500)} end
        )

      {:ok, result} =
        run_with_tool(verbose, [
          weather_call(),
          TestProvider.text_response("Done.")
        ])

      tool_result =
        result.messages
        |> Enum.flat_map(fn
          %{content: blocks} when is_list(blocks) -> blocks
          _ -> []
        end)
        |> Enum.find_value(fn
          %{type: "tool_result", content: content} -> content
          _ -> nil
        end)

      assert tool_result =~ "[truncated 500 -> 100 chars]"
    end

    test "tool context reaches inline tools" do
      test_pid = self()

      spy =
        weather_tool(
          execute: fn _input, context ->
            send(test_pid, {:ctx, context})
            {:ok, "ok"}
          end
        )

      {:ok, pid} =
        TestProvider.start_link([
          weather_call(),
          TestProvider.text_response("Done.")
        ])

      {:ok, _result} =
        Alloy.run("hi",
          provider: {TestProvider, agent_pid: pid},
          tools: [spy],
          working_directory: "/tmp",
          context: %{tenant: "acme"}
        )

      assert_received {:ctx, %{tenant: "acme", working_directory: "/tmp"}}
    end

    test "concurrent?: false forces sequential execution" do
      test_pid = self()

      slow = fn name ->
        Alloy.Tool.inline(
          name: name,
          description: "slow tool",
          input_schema: %{type: "object", properties: %{}},
          concurrent?: false,
          execute: fn _input, _context ->
            send(test_pid, {:started, name, System.monotonic_time(:millisecond)})
            Process.sleep(30)
            send(test_pid, {:finished, name, System.monotonic_time(:millisecond)})
            {:ok, "done"}
          end
        )
      end

      {:ok, pid} =
        TestProvider.start_link([
          TestProvider.tool_use_response([
            %{type: "tool_use", id: "c1", name: "slow_a", input: %{}},
            %{type: "tool_use", id: "c2", name: "slow_b", input: %{}}
          ]),
          TestProvider.text_response("Done.")
        ])

      {:ok, _result} =
        Alloy.run("go",
          provider: {TestProvider, agent_pid: pid},
          tools: [slow.("slow_a"), slow.("slow_b")]
        )

      assert_received {:started, "slow_a", _}
      assert_received {:finished, "slow_a", a_done}
      assert_received {:started, "slow_b", b_start}
      assert_received {:finished, "slow_b", _}

      # Sequential: b must not start before a finished.
      assert b_start >= a_done
    end
  end
end
