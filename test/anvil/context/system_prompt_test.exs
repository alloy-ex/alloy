defmodule Anvil.Context.SystemPromptTest do
  use ExUnit.Case, async: true

  alias Anvil.Context.SystemPrompt

  describe "build/2" do
    test "returns base prompt when no sections" do
      assert SystemPrompt.build("You are a helpful assistant.") ==
               "You are a helpful assistant."
    end

    test "appends sections with separators" do
      result =
        SystemPrompt.build("Base prompt.", tools: "Tool info here", context: "Context here")

      assert result =~ "Base prompt."
      assert result =~ "Tool info here"
      assert result =~ "Context here"
      # Sections should be separated
      assert result =~ "\n\n"
    end

    test "handles empty base with sections" do
      result = SystemPrompt.build("", rules: "Be concise")
      assert result =~ "Be concise"
    end
  end

  describe "with_tool_descriptions/2" do
    test "appends available tools section" do
      tool_defs = [
        %{name: "read_file", description: "Reads a file from disk"},
        %{name: "write_file", description: "Writes content to a file"}
      ]

      result = SystemPrompt.with_tool_descriptions("Base prompt.", tool_defs)

      assert result =~ "Base prompt."
      assert result =~ "## Available Tools"
      assert result =~ "read_file"
      assert result =~ "Reads a file from disk"
      assert result =~ "write_file"
      assert result =~ "Writes content to a file"
    end

    test "returns base prompt when no tools" do
      result = SystemPrompt.with_tool_descriptions("Base prompt.", [])
      assert result == "Base prompt."
    end
  end
end
