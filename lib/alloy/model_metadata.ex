defmodule Alloy.ModelMetadata do
  @moduledoc """
  Provider model metadata used for context budgeting.

  The primary consumer today is `Alloy.Context.Compactor`, but this module
  keeps model-window knowledge in one place so provider updates do not require
  editing token estimation logic directly.
  """

  @type model_entry :: %{
          name: String.t(),
          limit: pos_integer(),
          suffix_patterns: [String.t() | Regex.t()]
        }

  @type override_entry ::
          pos_integer()
          | %{
              required(:limit) => pos_integer(),
              optional(:suffix_patterns) => [String.t() | Regex.t()]
            }

  @default_limit 200_000

  @model_entries [
    %{name: "o3-pro", limit: 200_000, suffix_patterns: [""]},
    %{name: "gemini-flash-latest", limit: 1_048_576, suffix_patterns: [""]},
    %{name: "claude-opus-4-6", limit: 200_000, suffix_patterns: ["", ~r/^-\d{8}$/]},
    %{name: "claude-sonnet-4-6", limit: 200_000, suffix_patterns: ["", ~r/^-\d{8}$/]},
    %{name: "claude-haiku-4-5", limit: 200_000, suffix_patterns: ["", ~r/^-\d{8}$/]},
    %{name: "gpt-5", limit: 400_000, suffix_patterns: ["", ~r/^-\d{4}-\d{2}-\d{2}$/]},
    %{name: "gpt-5.1", limit: 400_000, suffix_patterns: ["", ~r/^-\d{4}-\d{2}-\d{2}$/]},
    %{name: "gpt-5.2", limit: 400_000, suffix_patterns: ["", ~r/^-\d{4}-\d{2}-\d{2}$/]},
    %{name: "gpt-5.4", limit: 1_050_000, suffix_patterns: ["", ~r/^-\d{4}-\d{2}-\d{2}$/]},
    %{
      name: "gemini-2.5-flash",
      limit: 1_048_576,
      suffix_patterns: ["", ~r/^-preview-\d{2}-\d{4}$/]
    },
    %{
      name: "gemini-2.5-pro",
      limit: 1_048_576,
      suffix_patterns: ["", ~r/^-preview-\d{2}-\d{4}$/]
    },
    %{
      name: "gemini-2.5-flash-lite",
      limit: 1_048_576,
      suffix_patterns: ["", ~r/^-preview-\d{2}-\d{4}$/]
    },
    %{
      name: "gemini-3-flash-preview",
      limit: 1_048_576,
      suffix_patterns: ["", ~r/^-\d{2}-\d{4}$/]
    },
    %{name: "gemini-3-pro-preview", limit: 1_048_576, suffix_patterns: ["", ~r/^-\d{2}-\d{4}$/]},
    %{name: "grok-4", limit: 2_000_000, suffix_patterns: [""]},
    %{name: "grok-4-fast-reasoning", limit: 2_000_000, suffix_patterns: [""]},
    %{name: "grok-4-fast-non-reasoning", limit: 2_000_000, suffix_patterns: [""]},
    # grok-4.20 family — current xAI frontier API models. The `-0309`
    # suffix is a date stamp; regex patterns accept any 4-digit stamp so
    # future snapshots on the same family won't need a code change.
    %{
      name: "grok-4.20",
      limit: 2_000_000,
      suffix_patterns: [~r/^-\d{4}-(reasoning|non-reasoning)$/, ~r/^-multi-agent-\d{4}$/]
    },
    # Dash notation (grok-4-1-fast-*) for backward compat
    %{name: "grok-4-1-fast-reasoning", limit: 2_000_000, suffix_patterns: [""]},
    %{name: "grok-4-1-fast-non-reasoning", limit: 2_000_000, suffix_patterns: [""]},
    # Dot notation (grok-4.1-fast*) matching actual xAI API model IDs
    %{
      name: "grok-4.1-fast",
      limit: 2_000_000,
      suffix_patterns: ["", "-reasoning", "-non-reasoning"]
    },
    %{name: "grok-code-fast-1", limit: 256_000, suffix_patterns: [""]},
    %{name: "grok-3", limit: 131_072, suffix_patterns: ["", "-fast"]},
    %{name: "grok-3-mini", limit: 131_072, suffix_patterns: ["", "-fast"]},
    # Kimi (Moonshot AI) — OpenAICompat via api.moonshot.ai
    %{name: "kimi-k2.5", limit: 256_000, suffix_patterns: [""]},
    %{name: "kimi-k2.6", limit: 256_000, suffix_patterns: [""]},
    # Gemma 4 (Google open-weight via Gemini API)
    %{
      name: "gemma-4",
      limit: 256_000,
      suffix_patterns: ["", ~r/^-\d{1,3}b$/, ~r/^-\d{1,3}b-it$/, ~r/^-\d{1,3}b-a\d+b-it$/]
    },
    # GLM (Zhipu AI) — OpenAICompat via open.bigmodel.cn
    %{name: "glm-4.6", limit: 200_000, suffix_patterns: [""]},
    # Qwen 3 family (Alibaba) — OpenAICompat via dashscope
    %{
      name: "qwen3-max",
      limit: 256_000,
      suffix_patterns: ["", "-preview"]
    },
    %{name: "qwen3-coder-plus", limit: 1_000_000, suffix_patterns: [""]},
    %{name: "qwen3-vl-plus", limit: 256_000, suffix_patterns: [""]},
    %{name: "qwen3-omni-flash", limit: 256_000, suffix_patterns: [""]},
    %{name: "qwen3.5-397b-a17b", limit: 1_000_000, suffix_patterns: [""]},
    # Mistral Large 3 — OpenAICompat via api.mistral.ai
    %{
      name: "mistral-large",
      limit: 256_000,
      suffix_patterns: ["-2512", "-latest"]
    }
  ]

  @doc """
  Returns the known context window limit for a model name.

  `overrides` may provide exact-model or family overrides as either:

  - `%{"model-name" => 1_000_000}`
  - `%{"model-name" => %{limit: 1_000_000, suffix_patterns: ["", ~r/^-\d+$/]}}`

  For overrides that only provide a limit, existing catalog suffix patterns are
  reused when available; unknown models default to exact-match only.

  Returns `nil` when the model is not in the current catalog or overrides.
  """
  @spec context_window(
          String.t(),
          %{optional(String.t()) => override_entry()} | [{String.t(), override_entry()}]
        ) ::
          pos_integer() | nil
  def context_window(model_name, overrides \\ %{}) when is_binary(model_name) do
    entries = override_entries(overrides) ++ @model_entries

    Enum.find_value(entries, fn entry ->
      if match_entry?(entry, model_name), do: entry.limit
    end)
  end

  @doc """
  Returns the default fallback context window for unknown models.
  """
  @spec default_context_window() :: pos_integer()
  def default_context_window, do: @default_limit

  @doc """
  Returns the known model catalog.
  """
  @spec catalog() :: [model_entry()]
  def catalog, do: @model_entries

  defp override_entries(overrides) when is_map(overrides) do
    overrides
    |> Enum.map(&build_override_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp override_entries(overrides) when is_list(overrides) do
    overrides
    |> Enum.map(&build_override_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp override_entries(_), do: []

  defp build_override_entry({name, limit})
       when is_binary(name) and is_integer(limit) and limit > 0 do
    %{name: name, limit: limit, suffix_patterns: override_suffix_patterns(name, nil)}
  end

  defp build_override_entry({name, %{limit: limit} = override})
       when is_binary(name) and is_integer(limit) and limit > 0 do
    %{name: name, limit: limit, suffix_patterns: override_suffix_patterns(name, override)}
  end

  defp build_override_entry({name, override}) when is_binary(name) and is_list(override) do
    build_override_entry({name, Map.new(override)})
  end

  defp build_override_entry(_), do: nil

  defp override_suffix_patterns(_name, %{suffix_patterns: suffix_patterns})
       when is_list(suffix_patterns) do
    suffix_patterns
  end

  defp override_suffix_patterns(name, _override) do
    case Enum.find(@model_entries, &(&1.name == name)) do
      %{suffix_patterns: suffix_patterns} -> suffix_patterns
      nil -> [""]
    end
  end

  defp match_entry?(%{name: name, suffix_patterns: suffix_patterns}, model_name) do
    case String.trim_leading(model_name, name) do
      ^model_name ->
        false

      suffix ->
        Enum.any?(suffix_patterns, &match_suffix?(&1, suffix))
    end
  end

  defp match_suffix?(suffix, candidate) when is_binary(suffix), do: suffix == candidate
  defp match_suffix?(%Regex{} = suffix, candidate), do: Regex.match?(suffix, candidate)
end
