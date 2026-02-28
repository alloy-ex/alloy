defmodule Alloy.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Alloy.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Alloy.Supervisor)
  end
end
