defmodule Anvil.Context.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Anvil.Context.Discovery
  alias Anvil.Agent.Config

  setup do
    base = Path.join(System.tmp_dir!(), "anvil_discovery_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    # Simulate a home dir, a git-root project, and a cwd inside it
    home = Path.join(base, "home")
    project = Path.join(base, "project")
    cwd = Path.join(project, "lib/deep")

    File.mkdir_p!(Path.join(home, ".anvil/context"))
    File.mkdir_p!(Path.join(project, ".git"))
    File.mkdir_p!(Path.join(project, ".anvil/context"))
    File.mkdir_p!(cwd)

    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, base: base, home: home, project: project, cwd: cwd}
  end

  describe "discover/1" do
    test "returns empty list when no context files exist", %{home: home, cwd: cwd} do
      # Dirs exist but have no .md files
      assert Discovery.discover(home: home, working_directory: cwd) == []
    end

    test "discovers global context files from ~/.anvil/context/", %{home: home, cwd: cwd} do
      File.write!(Path.join(home, ".anvil/context/rules.md"), "Be concise")

      result = Discovery.discover(home: home, working_directory: cwd)
      assert length(result) == 1
      assert {"rules", "Be concise"} in result
    end

    test "discovers project context files from git root", %{
      home: home,
      project: project,
      cwd: cwd
    } do
      File.write!(Path.join(project, ".anvil/context/project.md"), "Project context")

      result = Discovery.discover(home: home, working_directory: cwd)
      assert length(result) == 1
      assert {"project", "Project context"} in result
    end

    test "merges global and project files in order (global first)", %{
      home: home,
      project: project,
      cwd: cwd
    } do
      File.write!(Path.join(home, ".anvil/context/alpha.md"), "Global alpha")
      File.write!(Path.join(project, ".anvil/context/beta.md"), "Project beta")

      result = Discovery.discover(home: home, working_directory: cwd)
      assert length(result) == 2
      # Global comes first
      assert Enum.at(result, 0) == {"alpha", "Global alpha"}
      assert Enum.at(result, 1) == {"beta", "Project beta"}
    end

    test "sorts files alphabetically within each tier", %{home: home, cwd: cwd} do
      File.write!(Path.join(home, ".anvil/context/zebra.md"), "Z content")
      File.write!(Path.join(home, ".anvil/context/alpha.md"), "A content")

      result = Discovery.discover(home: home, working_directory: cwd)
      assert [{"alpha", "A content"}, {"zebra", "Z content"}] = result
    end

    test "ignores non-.md files", %{home: home, cwd: cwd} do
      File.write!(Path.join(home, ".anvil/context/notes.md"), "Keep me")
      File.write!(Path.join(home, ".anvil/context/notes.txt"), "Ignore me")
      File.write!(Path.join(home, ".anvil/context/config.yaml"), "Ignore me too")

      result = Discovery.discover(home: home, working_directory: cwd)
      assert length(result) == 1
      assert {"notes", "Keep me"} in result
    end

    test "discovers cwd-level context files (third tier)", %{
      home: home,
      project: project,
      cwd: cwd
    } do
      File.mkdir_p!(Path.join(cwd, ".anvil/context"))
      File.write!(Path.join(cwd, ".anvil/context/local.md"), "CWD context")
      File.write!(Path.join(project, ".anvil/context/project.md"), "Project context")

      result = Discovery.discover(home: home, working_directory: cwd)
      assert length(result) == 2
      # Project (git root) comes before cwd
      assert Enum.at(result, 0) == {"project", "Project context"}
      assert Enum.at(result, 1) == {"local", "CWD context"}
    end

    test "handles missing .anvil/context directories gracefully" do
      nowhere =
        Path.join(System.tmp_dir!(), "anvil_nowhere_#{System.unique_integer([:positive])}")

      assert Discovery.discover(home: nowhere, working_directory: nowhere) == []
    end

    test "detects git root by walking parent dirs", %{
      home: home,
      project: project,
      cwd: cwd
    } do
      # cwd is project/lib/deep, git root is project/
      File.write!(Path.join(project, ".anvil/context/found.md"), "Found via git root")

      result = Discovery.discover(home: home, working_directory: cwd)
      assert {"found", "Found via git root"} in result
    end

    test "does not duplicate when cwd IS the git root", %{home: home, project: project} do
      File.write!(Path.join(project, ".anvil/context/only_once.md"), "Once")

      result = Discovery.discover(home: home, working_directory: project)
      assert length(result) == 1
      assert {"only_once", "Once"} in result
    end
  end

  describe "Config integration" do
    test "context_discovery: true merges discovered files into system_prompt", %{
      home: home,
      project: project,
      cwd: cwd
    } do
      File.write!(Path.join(home, ".anvil/context/rules.md"), "Always be concise.")
      File.write!(Path.join(project, ".anvil/context/project.md"), "This is the Anvil project.")

      config =
        Config.from_opts(
          provider: Anvil.Provider.Test,
          system_prompt: "You are a helpful assistant.",
          context_discovery: true,
          working_directory: cwd,
          context: %{home: home}
        )

      assert config.system_prompt =~ "You are a helpful assistant."
      assert config.system_prompt =~ "Always be concise."
      assert config.system_prompt =~ "This is the Anvil project."
    end

    test "context_discovery: false (default) does not modify system_prompt" do
      config =
        Config.from_opts(
          provider: Anvil.Provider.Test,
          system_prompt: "Just a prompt."
        )

      assert config.system_prompt == "Just a prompt."
    end

    test "context_discovery: true with nil system_prompt uses discovered content as prompt", %{
      home: home,
      cwd: cwd
    } do
      File.write!(Path.join(home, ".anvil/context/rules.md"), "Discovered context only.")

      config =
        Config.from_opts(
          provider: Anvil.Provider.Test,
          context_discovery: true,
          working_directory: cwd,
          context: %{home: home}
        )

      assert config.system_prompt =~ "Discovered context only."
    end
  end
end
