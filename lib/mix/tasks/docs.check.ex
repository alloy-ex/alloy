defmodule Mix.Tasks.Docs.Check do
  use Mix.Task

  @shortdoc "Fail when public Alloy modules/functions are missing docs"

  @moduledoc """
  Enforces documentation coverage for Alloy public API modules.

  This task fails when:
  - a public Alloy module is missing `@moduledoc` (unless `@moduledoc false`)
  - a public function/macro is missing `@doc` (unless `@doc false`)

  Intended for CI usage:

      mix docs.check
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    modules = alloy_modules()

    findings =
      modules
      |> Enum.flat_map(&module_findings/1)
      |> Enum.sort()

    if findings == [] do
      Mix.shell().info("Docs check passed for #{length(modules)} Alloy modules.")
    else
      Mix.shell().error("Docs check failed with #{length(findings)} issue(s):")
      Enum.each(findings, &Mix.shell().error("  - " <> &1))
      Mix.raise("documentation coverage check failed")
    end
  end

  defp alloy_modules do
    app = Mix.Project.config()[:app]

    case :application.load(app) do
      :ok ->
        :ok

      {:error, {:already_loaded, ^app}} ->
        :ok

      {:error, reason} ->
        Mix.raise("failed to load #{inspect(app)} application: #{inspect(reason)}")
    end

    app
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(&public_alloy_module?/1)
  end

  defp public_alloy_module?(module) do
    module
    |> Atom.to_string()
    |> String.starts_with?("Elixir.Alloy")
  end

  defp module_findings(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, _language, _format, moduledoc, _metadata, docs} ->
        missing_module =
          if missing_doc?(moduledoc) do
            ["#{inspect(module)} missing @moduledoc (or @moduledoc false)"]
          else
            []
          end

        missing_functions =
          Enum.flat_map(docs, fn
            {{kind, name, arity}, line, _signatures, doc, _meta}
            when kind in [:function, :macro] ->
              if missing_doc?(doc) do
                ["#{inspect(module)}.#{name}/#{arity} missing @doc (line #{line})"]
              else
                []
              end

            _ ->
              []
          end)

        missing_module ++ missing_functions

      {:error, reason} ->
        ["#{inspect(module)} has no docs chunk: #{inspect(reason)}"]
    end
  end

  defp missing_doc?(:none), do: true
  defp missing_doc?(nil), do: true
  defp missing_doc?(_), do: false
end
