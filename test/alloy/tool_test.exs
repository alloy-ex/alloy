defmodule Alloy.ToolTest.MinimalTool do
  @moduledoc false
  @behaviour Alloy.Tool

  @impl true
  def name, do: "minimal_tool"

  @impl true
  def description, do: "A tool with only required callbacks"

  @impl true
  def input_schema, do: %{type: "object", properties: %{}, required: []}

  @impl true
  def execute(_input, _context), do: {:ok, "done"}
end

defmodule Alloy.ToolTest.AnnotatedTool do
  @moduledoc false
  @behaviour Alloy.Tool

  @impl true
  def name, do: "annotated_tool"

  @impl true
  def description, do: "A tool with optional callbacks implemented"

  @impl true
  def input_schema, do: %{type: "object", properties: %{}, required: []}

  @impl true
  def execute(_input, _context), do: {:ok, "done"}

  @impl true
  def allowed_callers, do: [:human, :code_execution]

  @impl true
  def result_type, do: :structured
end

defmodule Alloy.ToolTest do
  use ExUnit.Case, async: true

  alias Alloy.Tool

  describe "optional callbacks" do
    test "tool without optional callbacks compiles and works" do
      mod = Alloy.ToolTest.MinimalTool
      assert mod.name() == "minimal_tool"
      assert mod.execute(%{}, %{}) == {:ok, "done"}
      refute function_exported?(mod, :allowed_callers, 0)
      refute function_exported?(mod, :result_type, 0)
    end

    test "tool with optional callbacks exports them" do
      mod = Alloy.ToolTest.AnnotatedTool
      assert mod.name() == "annotated_tool"
      assert function_exported?(mod, :allowed_callers, 0)
      assert function_exported?(mod, :result_type, 0)
      assert mod.allowed_callers() == [:human, :code_execution]
      assert mod.result_type() == :structured
    end
  end

  describe "resolve_path/2" do
    test "absolute paths are returned as-is" do
      assert {:ok, "/usr/local/bin/elixir"} = Tool.resolve_path("/usr/local/bin/elixir", %{})

      assert {:ok, "/tmp/test.txt"} =
               Tool.resolve_path("/tmp/test.txt", %{working_directory: "/other"})
    end

    test "relative paths are joined with working_directory" do
      assert {:ok, "/project/mix.exs"} =
               Tool.resolve_path("mix.exs", %{working_directory: "/project"})
    end

    test "nested relative paths are joined correctly" do
      assert {:ok, "/project/lib/alloy.ex"} =
               Tool.resolve_path("lib/alloy.ex", %{working_directory: "/project"})
    end

    test "relative paths without working_directory expand from cwd" do
      assert {:ok, result} = Tool.resolve_path("mix.exs", %{})
      assert Path.type(result) == :absolute
      assert String.ends_with?(result, "/mix.exs")
    end

    test "relative paths with nil working_directory expand from cwd" do
      assert {:ok, result} = Tool.resolve_path("mix.exs", %{working_directory: nil})
      assert Path.type(result) == :absolute
      assert String.ends_with?(result, "/mix.exs")
    end

    test "handles dot-relative paths" do
      assert {:ok, "/project/test.txt"} =
               Tool.resolve_path("./test.txt", %{working_directory: "/project"})
    end

    test "handles parent directory references" do
      assert {:ok, "/project/other/file.ex"} =
               Tool.resolve_path("../other/file.ex", %{working_directory: "/project/lib"})
    end
  end

  describe "resolve_path/2 with :allowed_paths" do
    # Each test gets <tmp>/project (allowed) and <tmp>/project-secrets (not).
    setup %{tmp_dir: tmp_dir} do
      tmp_dir = real!(tmp_dir)
      project = Path.join(tmp_dir, "project")
      secrets = Path.join(tmp_dir, "project-secrets")
      File.mkdir_p!(Path.join(project, "lib"))
      File.mkdir_p!(secrets)
      File.write!(Path.join(project, "lib/app.ex"), "app")
      File.write!(Path.join(secrets, "key.txt"), "SECRET")

      {:ok,
       project: project,
       secrets: secrets,
       ctx: %{allowed_paths: [project], working_directory: project}}
    end

    @describetag :tmp_dir

    test "allows paths inside the root and the root itself", %{project: project, ctx: ctx} do
      assert {:ok, Path.join(project, "lib/app.ex")} ==
               Tool.resolve_path(Path.join(project, "lib/app.ex"), ctx)

      assert {:ok, project} == Tool.resolve_path(project, ctx)
    end

    test "a sibling that shares the root as a string prefix is outside", %{
      secrets: secrets,
      ctx: ctx
    } do
      assert {:error, msg} = Tool.resolve_path(Path.join(secrets, "key.txt"), ctx)
      assert msg =~ "outside allowed directories"
    end

    test "relative paths resolve against the working directory", %{project: project, ctx: ctx} do
      assert {:ok, Path.join(project, "lib/app.ex")} == Tool.resolve_path("lib/app.ex", ctx)
      assert {:error, _} = Tool.resolve_path("../project-secrets/key.txt", ctx)
    end

    test ".. segments cannot climb out of the root", %{project: project, ctx: ctx} do
      assert {:error, _} =
               Tool.resolve_path(Path.join(project, "../project-secrets/key.txt"), ctx)

      assert {:error, _} = Tool.resolve_path(Path.join(project, "lib/../../"), ctx)

      assert {:ok, Path.join(project, "lib/app.ex")} ==
               Tool.resolve_path(Path.join(project, "lib/../lib/app.ex"), ctx)
    end

    test "a write target that does not exist yet is allowed inside the root", %{
      project: project,
      ctx: ctx
    } do
      assert {:ok, Path.join(project, "new/dir/file.ex")} ==
               Tool.resolve_path("new/dir/file.ex", ctx)

      assert {:error, _} = Tool.resolve_path("../project-secrets/new.txt", ctx)
    end

    test "a symlink inside the root that points outside is rejected", %{
      project: project,
      secrets: secrets,
      ctx: ctx
    } do
      File.ln_s!(secrets, Path.join(project, "escape"))
      File.ln_s!(Path.join(secrets, "key.txt"), Path.join(project, "key_link"))
      File.ln_s!(Path.join(secrets, "missing.txt"), Path.join(project, "dangling"))

      assert {:error, _} = Tool.resolve_path("escape/key.txt", ctx)
      assert {:error, _} = Tool.resolve_path("key_link", ctx)
      assert {:error, _} = Tool.resolve_path("dangling", ctx)
    end

    test "returns the real path that was checked, so tools open that file", %{
      project: project,
      ctx: ctx
    } do
      File.ln_s!("lib/app.ex", Path.join(project, "alias.ex"))

      assert {:ok, Path.join(project, "lib/app.ex")} == Tool.resolve_path("alias.ex", ctx)
    end

    test "an allowed root reached through a symlink still matches", %{
      tmp_dir: tmp_dir,
      project: project
    } do
      link = Path.join(real!(tmp_dir), "project_link")
      File.ln_s!(project, link)
      ctx = %{allowed_paths: [link]}

      assert {:ok, Path.join(project, "lib/app.ex")} ==
               Tool.resolve_path(Path.join(link, "lib/app.ex"), ctx)
    end

    test "a symlink loop is an error, not an infinite loop", %{project: project, ctx: ctx} do
      File.ln_s!("loop", Path.join(project, "loop"))
      File.ln_s!("b", Path.join(project, "a"))
      File.ln_s!("a", Path.join(project, "b"))

      task = Task.async(fn -> {Tool.resolve_path("loop", ctx), Tool.resolve_path("a/x", ctx)} end)

      assert {{:error, loop_msg}, {:error, _}} = Task.await(task, 1_000)
      assert loop_msg =~ "symbolic links"
    end

    test "allowing / allows every absolute path", %{secrets: secrets} do
      path = Path.join(secrets, "key.txt")
      assert {:ok, ^path} = Tool.resolve_path(path, %{allowed_paths: ["/"]})
    end
  end

  # macOS puts tmp dirs under /var, a symlink to /private/var.
  defp real!(path) do
    {real, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(real)
  end
end
