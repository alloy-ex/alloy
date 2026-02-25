defmodule Anvil.SkillTest do
  use ExUnit.Case, async: true

  alias Anvil.Skill

  setup do
    base = Path.join(System.tmp_dir!(), "anvil_skill_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    home = Path.join(base, "home")
    project = Path.join(base, "project")

    File.mkdir_p!(Path.join(home, ".anvil/skills"))
    File.mkdir_p!(Path.join(project, ".anvil/skills"))

    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, base: base, home: home, project: project}
  end

  describe "parse/2" do
    test "parses valid frontmatter and body" do
      content = """
      ---
      name: code-review
      description: Review code for quality
      ---

      Review this code: {{input}}
      """

      skill = Skill.parse(content, "/tmp/code-review.md")
      assert skill.name == "code-review"
      assert skill.description == "Review code for quality"
      assert skill.body =~ "Review this code: {{input}}"
      assert skill.path == "/tmp/code-review.md"
    end

    test "uses filename as name when frontmatter has no name" do
      content = """
      ---
      description: A skill without a name
      ---

      Do something: {{input}}
      """

      skill = Skill.parse(content, "/tmp/my-skill.md")
      assert skill.name == "my-skill"
    end

    test "parses content with no frontmatter" do
      content = "Just a plain skill body with {{input}}"

      skill = Skill.parse(content, "/tmp/plain.md")
      assert skill.name == "plain"
      assert skill.description == nil
      assert skill.body == "Just a plain skill body with {{input}}"
    end

    test "handles empty frontmatter" do
      content = """
      ---
      ---

      Body content here.
      """

      skill = Skill.parse(content, "/tmp/empty-front.md")
      assert skill.name == "empty-front"
      assert skill.body =~ "Body content here."
    end
  end

  describe "apply/2" do
    test "replaces {{input}} placeholder" do
      skill = %Skill{
        name: "test",
        description: nil,
        body: "Review this: {{input}}",
        path: "/tmp/test.md"
      }

      result = Skill.apply(skill, "def foo, do: :bar")
      assert result == "Review this: def foo, do: :bar"
    end

    test "replaces multiple placeholders" do
      skill = %Skill{
        name: "test",
        description: nil,
        body: "Language: {{language}}\nCode: {{input}}",
        path: "/tmp/test.md"
      }

      result = Skill.apply(skill, %{"input" => "hello()", "language" => "elixir"})
      assert result == "Language: elixir\nCode: hello()"
    end

    test "leaves unmatched placeholders as-is" do
      skill = %Skill{
        name: "test",
        description: nil,
        body: "{{input}} and {{unknown}}",
        path: "/tmp/test.md"
      }

      result = Skill.apply(skill, "test input")
      assert result == "test input and {{unknown}}"
    end
  end

  describe "discover/1" do
    test "discovers skills from global directory", %{home: home} do
      File.write!(Path.join(home, ".anvil/skills/review.md"), """
      ---
      name: review
      description: Code review
      ---

      Review: {{input}}
      """)

      skills = Skill.discover(home: home, project: "/nonexistent")
      assert length(skills) == 1
      assert hd(skills).name == "review"
    end

    test "discovers skills from project directory", %{home: home, project: project} do
      File.write!(Path.join(project, ".anvil/skills/deploy.md"), """
      ---
      name: deploy
      description: Deploy guide
      ---

      Deploy: {{input}}
      """)

      skills = Skill.discover(home: home, project: project)
      assert length(skills) == 1
      assert hd(skills).name == "deploy"
    end

    test "project skills override global skills with same filename", %{
      home: home,
      project: project
    } do
      File.write!(Path.join(home, ".anvil/skills/review.md"), """
      ---
      name: review
      description: Global review
      ---
      Global review body
      """)

      File.write!(Path.join(project, ".anvil/skills/review.md"), """
      ---
      name: review
      description: Project review
      ---
      Project review body
      """)

      skills = Skill.discover(home: home, project: project)
      assert length(skills) == 1
      assert hd(skills).description == "Project review"
      assert hd(skills).body =~ "Project review body"
    end

    test "merges global and project skills with different names", %{
      home: home,
      project: project
    } do
      File.write!(Path.join(home, ".anvil/skills/global.md"), """
      ---
      name: global-skill
      ---
      Global body
      """)

      File.write!(Path.join(project, ".anvil/skills/project.md"), """
      ---
      name: project-skill
      ---
      Project body
      """)

      skills = Skill.discover(home: home, project: project)
      assert length(skills) == 2
      names = Enum.map(skills, & &1.name) |> Enum.sort()
      assert names == ["global-skill", "project-skill"]
    end

    test "returns empty list when no skill directories exist" do
      nowhere = Path.join(System.tmp_dir!(), "anvil_nowhere_#{System.unique_integer([:positive])}")
      assert Skill.discover(home: nowhere, project: nowhere) == []
    end

    test "ignores non-.md files", %{home: home} do
      File.write!(Path.join(home, ".anvil/skills/valid.md"), "Skill body")
      File.write!(Path.join(home, ".anvil/skills/invalid.txt"), "Not a skill")

      skills = Skill.discover(home: home, project: "/nonexistent")
      assert length(skills) == 1
    end
  end
end
