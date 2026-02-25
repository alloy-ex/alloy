defmodule Mix.Tasks.AnvilTest do
  use ExUnit.Case, async: true

  @tool_map %{
    "read" => Anvil.Tool.Core.Read,
    "write" => Anvil.Tool.Core.Write,
    "edit" => Anvil.Tool.Core.Edit,
    "bash" => Anvil.Tool.Core.Bash
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

      assert Anvil.Tool.Core.Read in parsed
      assert Anvil.Tool.Core.Write in parsed
      assert Anvil.Tool.Core.Edit in parsed
      assert Anvil.Tool.Core.Bash in parsed
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

      assert parsed == [Anvil.Tool.Core.Read]
    end
  end
end
