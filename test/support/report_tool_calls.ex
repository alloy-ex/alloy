defmodule Alloy.Test.ReportToolCalls do
  @moduledoc false
  # Middleware that sends {:before_tool_call, name} to context.report_to.
  @behaviour Alloy.Middleware

  @impl true
  def call(:before_tool_call, state) do
    %{name: name} = state.config.context.current_tool_call
    send(state.config.context.report_to, {:before_tool_call, name})
    state
  end

  def call(_hook, state), do: state
end
