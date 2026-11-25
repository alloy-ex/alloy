# OpenTelemetry Tracing Recipe

Alloy emits structured `:telemetry` spans and events without pulling
OpenTelemetry into its core dependencies. You can bridge them to OpenTelemetry
(following the OpenTelemetry GenAI semantic conventions) in your application
startup with ~80 lines of Elixir.

When `:timeout_ms` is finite, Alloy's supervised HTTP/SSE and custom bash
workers automatically propagate your process's OpenTelemetry context
(`:"$__current_otel_ctx"`), so child Finch/HTTP spans stay parented under the
active Alloy span.

## Dependencies (in your host application)

```elixir
defp deps do
  [
    {:alloy, "~> 0.14"},
    {:opentelemetry_api, "~> 1.4"},
    {:opentelemetry_telemetry, "~> 1.1"}
  ]
end
```

## Telemetry Bridge Module

Attach once in `Application.start/2`:

```elixir
defmodule MyApp.AlloyOtel do
  @moduledoc "Bridges Alloy :telemetry events to OpenTelemetry GenAI spans."

  require OpenTelemetry.Tracer, as: Tracer

  @handler_id "myapp-alloy-otel"

  @events [
    [:alloy, :run, :start],
    [:alloy, :run, :stop],
    [:alloy, :run, :exception],
    [:alloy, :turn, :start],
    [:alloy, :turn, :stop],
    [:alloy, :turn, :exception],
    [:alloy, :provider, :request],
    [:alloy, :tool, :stop],
    [:alloy, :compaction, :done]
  ]

  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
  end

  def handle_event([:alloy, :run, :start], _measurements, meta, _cfg) do
    OpentelemetryTelemetry.start_telemetry_span(@handler_id, "alloy.run", meta, %{
      "gen_ai.operation.name" => "invoke_agent",
      "gen_ai.request.model" => to_string(meta[:model] || "")
    })
  end

  def handle_event([:alloy, :run, :stop], %{duration_ms: duration_ms}, meta, _cfg) do
    OpentelemetryTelemetry.set_current_telemetry_span(@handler_id, meta)

    Tracer.set_attributes(%{
      "alloy.status" => to_string(meta[:status]),
      "alloy.turns" => meta[:turns] || 0,
      "alloy.duration_ms" => duration_ms
    })

    OpentelemetryTelemetry.end_telemetry_span(@handler_id, meta)
  end

  def handle_event([:alloy, :run, :exception], _measurements, meta, _cfg) do
    OpentelemetryTelemetry.set_current_telemetry_span(@handler_id, meta)
    Tracer.set_status(:error, inspect(meta[:reason]))
    OpentelemetryTelemetry.end_telemetry_span(@handler_id, meta)
  end

  def handle_event([:alloy, :turn, :start], _measurements, meta, _cfg) do
    OpentelemetryTelemetry.start_telemetry_span(@handler_id, "alloy.turn", meta, %{
      "alloy.turn" => meta[:turn]
    })
  end

  def handle_event([:alloy, :turn, :stop], _measurements, meta, _cfg) do
    OpentelemetryTelemetry.set_current_telemetry_span(@handler_id, meta)
    Tracer.set_attribute("alloy.status", to_string(meta[:status]))
    OpentelemetryTelemetry.end_telemetry_span(@handler_id, meta)
  end

  def handle_event([:alloy, :turn, :exception], _measurements, meta, _cfg) do
    OpentelemetryTelemetry.set_current_telemetry_span(@handler_id, meta)
    Tracer.set_status(:error, inspect(meta[:reason]))
    OpentelemetryTelemetry.end_telemetry_span(@handler_id, meta)
  end

  # Alloy emits [:alloy, :provider, :request] once per attempt with duration_ms.
  def handle_event([:alloy, :provider, :request], %{duration_ms: duration_ms}, meta, _cfg) do
    Tracer.add_event("gen_ai.provider.request", %{
      "gen_ai.provider.name" => inspect(meta[:provider]),
      "gen_ai.request.model" => to_string(meta[:model] || ""),
      "alloy.streaming" => meta[:streaming],
      "alloy.attempt" => meta[:attempt],
      "alloy.result" => to_string(meta[:result]),
      "alloy.duration_ms" => duration_ms
    })
  end

  # Parallel tool calls emit all :tool, :start events upfront on the caller process,
  # so recording completed tools as events (or explicit-timestamp child spans) on
  # [:alloy, :tool, :stop] avoids nesting concurrent tools on the process span stack.
  def handle_event([:alloy, :tool, :stop], %{duration_ms: duration_ms}, meta, _cfg) do
    Tracer.add_event("gen_ai.tool.execute", %{
      "gen_ai.tool.name" => to_string(meta[:tool_name] || ""),
      "gen_ai.tool.call.id" => to_string(meta[:tool_id] || ""),
      "alloy.turn" => meta[:turn],
      "alloy.duration_ms" => duration_ms,
      "alloy.tool.is_error" => not is_nil(meta[:error])
    })
  end

  def handle_event([:alloy, :compaction, :done], measurements, meta, _cfg) do
    Tracer.add_event("alloy.compaction.done", %{
      "alloy.turn" => meta[:turn],
      "alloy.messages_before" => measurements[:messages_before],
      "alloy.messages_after" => measurements[:messages_after]
    })
  end
end
```

## Notes

- **Context propagation:** Alloy copies `:"$__current_otel_ctx"` into
  supervised HTTP/SSE and custom bash workers, so downstream Finch/HTTP spans
  stay linked to your active `alloy.turn` span.
- **Usage attributes:** Attach `result.usage` (`input_tokens`, `output_tokens`,
  `cache_read_input_tokens`, `cache_creation_input_tokens`) at the `Alloy.run/2`
  call site or inside `:after_completion` middleware to record token totals on
  the root span.
- **No prompt/PII leakage:** Alloy's `:telemetry` metadata intentionally omits
  prompt bodies, tool arguments, and model outputs. Attach redacting middleware
  only if you explicitly want content attributes in traces.
