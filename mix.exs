defmodule Alloy.MixProject do
  use Mix.Project

  @version "0.13.0"
  @source_url "https://github.com/alloy-ex/alloy"

  def project do
    [
      app: :alloy,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Model-agnostic agent harness for Elixir",
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        # Third-party callers rely on our specs, so hold them to what the
        # code actually returns.
        flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
      ],
      test_coverage: [
        # Ratchet: raise as coverage improves, never lower it.
        summary: [threshold: 90],
        ignore_modules: [~r/^Alloy\.Test\./, Alloy.StreamTestHelpers]
      ],
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  # `mix ci` runs every gate CI enforces, in the order that fails fastest.
  # Docs build separately (`MIX_ENV=dev mix docs --warnings-as-errors`)
  # because ex_doc is a dev-only dependency.
  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "hex.audit",
        "compile --warnings-as-errors --force",
        "xref graph --format cycles --label compile-connected --fail-above 0",
        "credo",
        "test --warnings-as-errors --cover",
        "dialyzer"
      ]
    ]
  end

  def application do
    [
      mod: {Alloy.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Req 0.6.1 fixes GHSA-655f-mp8p-96gv (decompression bomb).
      # Bound the tested API range while allowing the patched 0.6 line.
      {:req, ">= 0.6.1 and < 0.8.0"},
      # Not used directly: a security floor for the transport Req uses.
      # Downstream apps don't inherit our lockfile, so the constraint is the
      # only way to keep them off Mint < 1.11 (HTTP/1 DoS and smuggling CVEs)
      # and HPAX < 1.0.4. See CHANGELOG "Security".
      {:mint, "~> 1.11"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.19.5 or ~> 1.20.3", only: :test}
    ]
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Alloy",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "docs/upgrading-to-0.13.md",
        "docs/events.md",
        "docs/provider-compatibility.md",
        "docs/recipes/sub-agents.md",
        "docs/recipes/mcp-tools.md",
        "livebooks/quickstart.livemd"
      ],
      groups_for_extras: [
        Guides: ~r{docs/(upgrading-to-0\.13|events|provider-compatibility)\.md|livebooks/.*},
        Recipes: ~r{docs/recipes/.*}
      ],
      groups_for_modules: [
        Core: [
          Alloy,
          Alloy.Agent.Config,
          Alloy.Events,
          Alloy.ModelCatalog,
          Alloy.ModelMetadata,
          Alloy.Agent.State,
          Alloy.Agent.Turn,
          Alloy.Message,
          Alloy.Result,
          Alloy.Usage
        ],
        Providers: [
          Alloy.Provider,
          Alloy.Provider.Anthropic,
          Alloy.Provider.Codex,
          Alloy.Provider.Error,
          Alloy.Provider.Gemini,
          Alloy.Provider.OpenAI,
          Alloy.Provider.OpenAICompat,
          Alloy.Provider.Retry,
          Alloy.Provider.Test,
          Alloy.Provider.XAI
        ],
        Tools: [
          Alloy.Tool,
          Alloy.Tool.Inline,
          Alloy.Tool.Core.Bash,
          Alloy.Tool.Core.Read,
          Alloy.Tool.Core.Write,
          Alloy.Tool.Core.Edit,
          Alloy.Tool.Executor,
          Alloy.Tool.Registry
        ],
        Context: [
          Alloy.Context.Compactor
        ],
        Memory: [
          Alloy.Memory
        ],
        Middleware: [
          Alloy.Middleware
        ],
        Testing: [
          Alloy.Testing
        ]
      ]
    ]
  end
end
