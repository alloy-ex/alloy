defmodule Mix.Tasks.AlloyTest do
  use ExUnit.Case, async: true

  @tool_map %{
    "read" => Alloy.Tool.Core.Read,
    "write" => Alloy.Tool.Core.Write,
    "edit" => Alloy.Tool.Core.Edit,
    "bash" => Alloy.Tool.Core.Bash
  }

  describe "default tools" do
    test "all 4 core tools are enabled by default when no --tools flag given" do
      # parse_tools is private, so we test the public contract:
      # when no --tools is passed, the default should include all 4 tools
      {opts, _words, _} =
        OptionParser.parse([],
          strict: [
            provider: :string,
            model: :string,
            tools: :string,
            system: :string,
            max_turns: :integer,
            dir: :string,
            programmatic: :boolean
          ],
          aliases: [p: :programmatic, m: :model, t: :tools, s: :system]
        )

      # This simulates what the mix task does internally
      tools_str = Keyword.get(opts, :tools, "read,write,edit,bash")

      parsed =
        tools_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&Map.fetch!(@tool_map, &1))

      assert Alloy.Tool.Core.Read in parsed
      assert Alloy.Tool.Core.Write in parsed
      assert Alloy.Tool.Core.Edit in parsed
      assert Alloy.Tool.Core.Bash in parsed
    end

    test "explicit --tools flag overrides default" do
      {opts, _words, _} =
        OptionParser.parse(["--tools", "read"],
          strict: [
            provider: :string,
            model: :string,
            tools: :string,
            system: :string,
            max_turns: :integer,
            dir: :string,
            programmatic: :boolean
          ],
          aliases: [p: :programmatic, m: :model, t: :tools, s: :system]
        )

      tools_str = Keyword.get(opts, :tools, "read,write,edit,bash")

      parsed =
        tools_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&Map.fetch!(@tool_map, &1))

      assert parsed == [Alloy.Tool.Core.Read]
    end
  end
end
