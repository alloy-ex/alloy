defmodule Alloy.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children =
      [
        {Task.Supervisor, name: Alloy.TaskSupervisor}
      ] ++ maybe_pubsub()

    Supervisor.start_link(children, strategy: :one_for_one, name: Alloy.Supervisor)
  end

  # Start a local PubSub only when the user explicitly opts in via
  # `config :alloy, pubsub: Alloy.PubSub` (or any module name).
  # If phoenix_pubsub is not available, skip silently.
  defp maybe_pubsub do
    case Application.get_env(:alloy, :pubsub) do
      nil ->
        []

      name when is_atom(name) ->
        if Code.ensure_loaded?(Phoenix.PubSub) do
          [{Phoenix.PubSub, name: name}]
        else
          []
        end
    end
  end
end
