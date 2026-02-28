defmodule Alloy.MixProject do
  use Mix.Project

  @version "0.4.2"
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
        plt_add_apps: [:mix],
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
      {:req, "~> 0.5"},
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
      groups_for_modules: [
        Core: [
          Alloy,
          Alloy.Agent.Config,
          Alloy.Agent.Server,
          Alloy.Agent.State,
          Alloy.Agent.Turn,
          Alloy.Message,
          Alloy.Persistence,
          Alloy.Session,
          Alloy.Usage
        ],
        Providers: [
          Alloy.Provider,
          Alloy.Provider.Anthropic,
          Alloy.Provider.OpenAI,
          Alloy.Provider.Google,
          Alloy.Provider.Ollama,
          Alloy.Provider.OpenRouter,
          Alloy.Provider.XAI,
          Alloy.Provider.DeepSeek,
          Alloy.Provider.Mistral,
          Alloy.Provider.Test
        ],
        Tools: [
          Alloy.Tool,
          Alloy.Tool.Core.Bash,
          Alloy.Tool.Core.Read,
          Alloy.Tool.Core.Write,
          Alloy.Tool.Core.Edit,
          Alloy.Tool.Core.Scratchpad,
          Alloy.Tool.Executor,
          Alloy.Tool.Registry
        ],
        Context: [
          Alloy.Context.Compactor,
          Alloy.Context.Discovery,
          Alloy.Context.SystemPrompt,
          Alloy.Context.TokenCounter
        ],
        Middleware: [
          Alloy.Middleware,
          Alloy.Middleware.Logger,
          Alloy.Middleware.Telemetry
        ],
        Advanced: [
          Alloy.Team,
          Alloy.Scheduler,
          Alloy.Skill,
          Alloy.PubSub
        ],
        Testing: [
          Alloy.Testing
        ]
      ]
    ]
  end
end
