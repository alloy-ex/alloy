defmodule Alloy.MixProject do
  use Mix.Project

  @version "0.12.4"
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
        plt_core_path: "priv/plts/core.plt"
      ],
      elixirc_paths: elixirc_paths(Mix.env())
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
      # ~> 0.6 floor: req 0.6.0 fixes GHSA-px9f-whj3-246m (multipart header
      # injection) and GHSA-655f-mp8p-96gv (decompression bomb) — relevant
      # because Alloy can target user-configured OpenAI-compatible endpoints.
      {:req, "~> 0.6"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.16", only: :test},
      {:phoenix_pubsub, "~> 2.1", optional: true}
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
        "docs/events.md",
        "docs/recipes/sub-agents.md",
        "docs/recipes/mcp-tools.md",
        "livebooks/quickstart.livemd"
      ],
      groups_for_extras: [
        Guides: ~r{docs/events\.md|livebooks/.*},
        Recipes: ~r{docs/recipes/.*}
      ],
      groups_for_modules: [
        Core: [
          Alloy,
          Alloy.Agent.Config,
          Alloy.Agent.Server,
          Alloy.Events,
          Alloy.ModelCatalog,
          Alloy.ModelMetadata,
          Alloy.Agent.State,
          Alloy.Agent.Turn,
          Alloy.Message,
          Alloy.Result,
          Alloy.Session,
          Alloy.Usage
        ],
        Providers: [
          Alloy.Provider,
          Alloy.Provider.Anthropic,
          Alloy.Provider.Codex,
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
          Alloy.Memory,
          Alloy.Memory.Router
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
