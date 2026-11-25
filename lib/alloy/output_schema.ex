defmodule Alloy.OutputSchema do
  @moduledoc """
  Normalized representation of a portable `:output_schema` option.

  Built by `Alloy.Agent.Config.from_opts/1` and `Alloy.Agent.State.prepare/2`
  from either a plain JSON Schema map or a wrapper map
  `%{name: ..., schema: ..., strict: ...}`. Stored on `state.config.output_schema`
  so middleware can inspect it and built-in providers can translate it into
  their wire formats without re-normalizing per request.

  ## Semantics

  - **Provider translation & wrapper options:** Sent on every completion turn
    and forwarded to fallback providers (omitted on compaction summaries, which
    also drop raw `extra_body` `output_config`, `text`, `response_format`, and
    Gemini schema/thinking containers). `:name` (default `"alloy_output"`) and
    `:strict` (default `true`) apply to OpenAI, xAI, and OpenAICompat and are
    ignored on Anthropic, Gemini, and Codex. OpenAI/xAI strict mode requires
    every property in `"required"` and `"additionalProperties" => false` on
    every object (pass `%{schema: schema, strict: false}` to opt out).
  - **Provider compatibility:** Gemini models prior to Gemini 3 and some
    OpenAICompat servers reject combining `tools` with JSON Schema output; use
    Gemini 3+ (`gemini-3.8-flash`), `:until_tool` / `:stop_after_tool`, or a
    host-driven follow-up no-tools turn. On Gemini, conflicting
    `generation_config` / `extra_body["generationConfig"]` keys
    (`responseJsonSchema`, legacy `responseSchema`, snake_case equivalents, or
    non-JSON `responseMimeType`) fail locally with non-retryable
    `%Alloy.Provider.Error{kind: :invalid_request}`. Overriding a provider's
    wire schema key via `:extra_body` changes the wire payload only; Alloy still
    validates against the top-level `:output_schema`.
  - **Validation tiers:** Remote (non-`#`) `$ref`s are always rejected at
    startup. Full Draft 4/6/7 validation runs when optional `:ex_json_schema` is
    loaded (bounded to 10 errors / 1,000 bytes; Draft 7
    `contentMediaType: "application/json"` requires
    `config :ex_json_schema, decode_json: &Jason.decode/1`); without
    `:ex_json_schema` or for newer dialects (Draft 2019-09 / 2020-12), Alloy
    falls back to top-level JSON `"type"` and `"required"` checks only (logging
    a `Logger.warning` when `:ex_json_schema` is loaded and encounters an
    unsupported `$schema` dialect — pre-normalize once with `normalize!/1` if
    reusing a Draft 2019-09 / 2020-12 schema across runs to avoid per-run log
    warnings).
  - **Decoding & terminal failures:** Runs before `:after_completion` and is
    skipped when `:stop_after_tool` completes a run. Final assistant text blocks
    are joined with `""` for JSON decoding (whereas `result.text` joins blocks
    with `"\n"`). Invalid JSON, `:max_tokens` truncation (even when the prefix
    parses), refusals (taking precedence over `:until_tool` reminders), missing
    or whitespace-only text, and schema violations fail terminally with
    `{:error, result}` (`status: :error`, `output: nil`, and machine-readable
    `result.metadata.run.output_error` with
    `%{kind: :invalid_json | :schema_mismatch | :invalid_schema | :truncated | :refusal | :missing_text, message: String.t(), decoded: term() | nil}`).
    Runtime schema/configuration errors (such as missing `:ex_json_schema`
    `:decode_json` for `contentMediaType: "application/json"` or invalid local
    references) report `kind: :invalid_schema` with `decoded: nil` so host
    repair loops do not retry unfixable schema errors.
    Decode/validation failures and content-block refusals keep the assistant
    reply in `result.messages` / `result.text`, while stop-reason refusals
    discard the refused reply. If `:after_completion` halts with
    `{:halt, reason}` or `{:halt, reason, state}`, `result.status` is `:halted`
    and `result.output` is `nil` (the validated value was available on
    `state.run_metadata.output`). Alloy does not run an automatic repair turn.
  """

  alias Alloy.Tool.Validation

  @default_name "alloy_output"
  @name_pattern ~r/\A[a-zA-Z0-9_-]{1,64}\z/
  @wrapper_keys [:name, :schema, :strict, "name", "schema", "strict"]

  @derive {Inspect, except: [:resolved]}
  @enforce_keys [:name, :schema, :strict]
  defstruct [:name, :schema, :strict, :resolved]

  @typedoc """
  Normalized `:output_schema` struct.

  `:resolved` is an internal validation cache bound to `{name, schema, strict}`
  and excluded from `Inspect`.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          schema: map(),
          strict: boolean(),
          resolved: {:cached, {String.t(), map(), boolean()}, {:ok, term()} | :fallback} | nil
        }

  @type output_error_kind ::
          :invalid_json
          | :schema_mismatch
          | :invalid_schema
          | :truncated
          | :refusal
          | :missing_text

  @type output_error :: %{
          kind: output_error_kind(),
          message: String.t(),
          decoded: term() | nil
        }

  @doc """
  Normalizes `:output_schema` into `%Alloy.OutputSchema{}` or `nil`.

  Accepts `nil`, a `%Alloy.OutputSchema{}` struct (returned as-is if already
  normalized, or validated if hand-built), a plain JSON Schema map (defaulting
  `name: "alloy_output"` and `strict: true`), or a wrapper map
  `%{schema: map, name: ..., strict: ...}`. Raises `ArgumentError` on invalid
  shapes, non-JSON-encodable schemas, remote `$ref`s, or invalid schemas when
  `:ex_json_schema` is loaded.
  """
  @spec normalize!(term()) :: t() | nil
  def normalize!(nil), do: nil

  def normalize!(%__MODULE__{} = spec) do
    if valid_cache?(spec) do
      spec
    else
      normalize_wrapper!(%{name: spec.name, schema: spec.schema, strict: spec.strict})
    end
  end

  def normalize!(%_{} = struct) do
    raise ArgumentError,
          "output_schema must be a JSON Schema map or nil, got struct: #{inspect(struct.__struct__)}"
  end

  def normalize!(spec) when is_map(spec) and map_size(spec) > 0 do
    if wrapper_map?(spec) do
      normalize_wrapper!(spec)
    else
      {normalized, resolved} = normalize_schema!(spec, @default_name)

      %__MODULE__{
        name: @default_name,
        schema: normalized,
        strict: true,
        resolved: {:cached, {@default_name, normalized, true}, resolved}
      }
    end
  end

  def normalize!(other) do
    raise ArgumentError,
          "output_schema must be a non-empty JSON Schema map or nil, got: #{inspect(other)}"
  end

  @doc """
  Decodes final assistant text as JSON and validates it against `spec`.

  Uses full Draft 4/6/7 validation via optional `:ex_json_schema` when loaded
  and the schema dialect is supported; falls back to top-level JSON `"type"`
  and `"required"` checks otherwise. Returns `{:ok, decoded}` or
  `{:error, %{kind: kind, message: message, decoded: decoded | nil}}`.
  """
  @spec decode_and_validate(String.t() | nil, t() | map()) ::
          {:ok, term()} | {:error, output_error()}
  def decode_and_validate(text, spec)
      when (is_nil(text) or is_binary(text)) and is_map(spec) do
    %__MODULE__{schema: schema, resolved: {:cached, _key, resolution}} = normalize!(spec)

    if is_nil(text) or String.trim(text) == "" do
      {:error,
       %{
         kind: :missing_text,
         message: "Structured output is missing assistant text",
         decoded: nil
       }}
    else
      case Jason.decode(text) do
        {:ok, decoded} ->
          case validate_decoded(decoded, schema, resolution) do
            {:ok, value} ->
              {:ok, value}

            {:error, :invalid_schema, message} ->
              {:error, %{kind: :invalid_schema, message: message, decoded: nil}}

            {:error, message} ->
              {:error, %{kind: :schema_mismatch, message: message, decoded: decoded}}
          end

        {:error, reason} ->
          {:error,
           %{
             kind: :invalid_json,
             message: "Structured output is not valid JSON: #{Exception.message(reason)}",
             decoded: nil
           }}
      end
    end
  end

  # ── Normalization ────────────────────────────────────────────────────────

  defp wrapper_map?(map) do
    Map.has_key?(map, :schema) or Map.has_key?(map, "schema")
  end

  defp normalize_wrapper!(spec) do
    unknown_keys = Enum.reject(Map.keys(spec), &(&1 in @wrapper_keys))

    if unknown_keys != [] do
      raise ArgumentError,
            "output_schema wrapper map contains unsupported key(s): #{inspect(unknown_keys)}. " <>
              "Allowed wrapper keys are :name, :schema, and :strict " <>
              "(put schema metadata like \"description\" inside the :schema map)."
    end

    name = fetch_unique_key!(spec, :name, "name", @default_name)
    strict = fetch_unique_key!(spec, :strict, "strict", true)
    raw_schema = fetch_unique_key!(spec, :schema, "schema", nil)

    validate_name!(name)
    validate_strict!(strict)

    if is_map(raw_schema) and not is_struct(raw_schema) and map_size(raw_schema) > 0 do
      {normalized, resolved} = normalize_schema!(raw_schema, name)

      %__MODULE__{
        name: name,
        schema: normalized,
        strict: strict,
        resolved: {:cached, {name, normalized, strict}, resolved}
      }
    else
      raise ArgumentError,
            "output_schema :schema must be a non-empty JSON Schema map, got: #{inspect(raw_schema)}"
    end
  end

  defp fetch_unique_key!(map, atom_key, string_key, default) do
    case {Map.fetch(map, atom_key), Map.fetch(map, string_key)} do
      {{:ok, _}, {:ok, _}} ->
        raise ArgumentError,
              "output_schema cannot specify both #{inspect(atom_key)} and #{inspect(string_key)}"

      {{:ok, val}, :error} ->
        val

      {:error, {:ok, val}} ->
        val

      {:error, :error} ->
        default
    end
  end

  defp validate_name!(name) when is_binary(name) do
    unless Regex.match?(@name_pattern, name) do
      raise ArgumentError,
            "output_schema :name must match ^[a-zA-Z0-9_-]{1,64}$, got: #{inspect(name)}"
    end
  end

  defp validate_name!(name) do
    raise ArgumentError,
          "output_schema :name must be a string matching ^[a-zA-Z0-9_-]{1,64}$, got: #{inspect(name)}"
  end

  defp validate_strict!(strict) when is_boolean(strict), do: :ok

  defp validate_strict!(strict) do
    raise ArgumentError, "output_schema :strict must be a boolean, got: #{inspect(strict)}"
  end

  defp normalize_schema!(schema, name) do
    # Round-trip through strict JSON encoding so duplicate atom/string keys
    # (e.g. %{type: "object", "type" => "array"}) fail loudly and all map keys
    # are normalized to strings.
    normalized =
      try do
        schema
        |> Jason.encode!(maps: :strict)
        |> Jason.decode!()
      rescue
        e in [Jason.EncodeError, ArgumentError] ->
          reraise ArgumentError,
                  "Invalid output_schema #{inspect(name)}: #{Exception.message(e)}",
                  __STACKTRACE__
      end

    resolved = Validation.prepare_output_schema!(normalized, name)
    {normalized, resolved}
  end

  # ── Validation ───────────────────────────────────────────────────────────

  defp valid_cache?(%__MODULE__{
         name: name,
         schema: schema,
         strict: strict,
         resolved: {:cached, {name, schema, strict}, resolution}
       }) do
    Validation.valid_resolved_output?(resolution)
  end

  defp valid_cache?(_spec), do: false

  defp validate_decoded(decoded, _schema, {:ok, resolved}) do
    case Validation.validate_resolved_output(resolved, decoded) do
      :ok -> {:ok, decoded}
      {:error, :invalid_schema, reason} -> {:error, :invalid_schema, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_decoded(decoded, schema, :fallback) do
    validate_basic(decoded, schema)
  end

  defp validate_basic(decoded, schema) do
    with :ok <- check_type(decoded, Map.get(schema, "type")),
         :ok <- check_required(decoded, Map.get(schema, "required")) do
      {:ok, decoded}
    end
  end

  defp check_type(_val, nil), do: :ok
  defp check_type(val, "object") when is_map(val), do: :ok
  defp check_type(val, "array") when is_list(val), do: :ok
  defp check_type(val, "string") when is_binary(val), do: :ok
  defp check_type(val, "integer") when is_integer(val), do: :ok
  defp check_type(val, "integer") when is_float(val) and trunc(val) == val, do: :ok
  defp check_type(val, "number") when is_number(val), do: :ok
  defp check_type(val, "boolean") when is_boolean(val), do: :ok
  defp check_type(nil, "null"), do: :ok

  defp check_type(val, types) when is_list(types) do
    if Enum.any?(types, &(check_type(val, &1) == :ok)) do
      :ok
    else
      {:error, "Structured output did not match any expected JSON type #{inspect(types)}"}
    end
  end

  defp check_type(_val, expected) when is_binary(expected) do
    {:error, "Structured output expected JSON type #{inspect(expected)}"}
  end

  defp check_type(_val, _other), do: :ok

  defp check_required(val, required) when is_map(val) and is_list(required) do
    missing = Enum.filter(required, &(is_binary(&1) and not Map.has_key?(val, &1)))

    case missing do
      [] -> :ok
      keys -> {:error, "Structured output missing required keys: #{Enum.join(keys, ", ")}"}
    end
  end

  defp check_required(_val, _required), do: :ok
end
