defmodule Alloy.PubSub do
  @moduledoc """
  Optional PubSub integration for reactive agents.

  Allows agents to subscribe to topics and react to messages,
  or broadcast results to subscribers.

  ## Dependency

  This module requires `phoenix_pubsub`, which is an optional dependency.
  Add it to your `mix.exs` if you want to use PubSub features:

      {:phoenix_pubsub, "~> 2.1"}

  ## Usage

  Add `Alloy.PubSub` to your application's supervision tree:

      children = [
        {Alloy.PubSub, name: MyApp.PubSub}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

  Then configure agents to use it:

      {:ok, agent} = Alloy.Agent.Server.start_link(
        provider: ...,
        pubsub: MyApp.PubSub,
        subscribe: ["tasks:new"]
      )

  The agent will now process any messages broadcast to "tasks:new".

  ## Topic Stability

  The response topic is `"agent:<id>:responses"` where `<id>` is a stable
  identifier derived from `context[:session_id]` (if provided) or an
  auto-generated random ID. The ID is assigned once at agent startup and
  remains stable for the process lifetime.

  For agents that restart under a supervisor, pass a stable `session_id`
  via the `:context` option so subscribers can predict the topic:

      Server.start_link(
        provider: ...,
        pubsub: MyApp.PubSub,
        context: %{session_id: "my-agent-1"}
      )

      # Subscribers can use a known topic:
      Phoenix.PubSub.subscribe(MyApp.PubSub, "agent:my-agent-1:responses")
  """

  @doc "Returns the child spec for starting a PubSub supervisor."
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Phoenix.PubSub.child_spec(name: name)
  end

  @doc "Subscribe the current process to a PubSub topic."
  @spec subscribe(String.t(), keyword()) :: :ok | {:error, term()}
  def subscribe(topic, opts \\ []) do
    pubsub = Keyword.get(opts, :pubsub, __MODULE__)
    Phoenix.PubSub.subscribe(pubsub, topic)
  end

  @doc "Broadcast a message to all subscribers of a topic."
  @spec broadcast(String.t(), term(), keyword()) :: :ok | {:error, term()}
  def broadcast(topic, event, opts \\ []) do
    pubsub = Keyword.get(opts, :pubsub, __MODULE__)
    Phoenix.PubSub.broadcast(pubsub, topic, event)
  end
end
