defmodule Kleened.Core.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  require Logger

  use Application

  def start_link() do
    start(nil, nil)
  end

  def api_socket_listeners() do
    # Apparantly this function is called before the supervisor begin starting its children, thus the Kleened.Core.Config is not started.

    listeners = Kleened.Core.Config.get("api_listeners")
    indexed_listeners = Enum.zip(Enum.to_list(1..length(listeners)), listeners)

    Enum.map(indexed_listeners, fn {index, {scheme, cowboy_options}} ->
      Plug.Cowboy.child_spec(
        scheme: scheme,
        plug: String.to_atom("Listener#{index}"),
        options: [{:dispatch, Kleened.API.Router.dispatch()} | cowboy_options]
      )
    end)
  end

  def start(_type, _args) do
    {:ok, pid} = Kleened.Core.Config.start_link([])

    children = [
      Kleened.Core.Config,
      Kleened.Core.MetaData,
      Kleened.Core.Layer,
      Kleened.Core.Network,
      {Registry, keys: :unique, name: Kleened.Core.ExecInstances},
      {DynamicSupervisor, name: Kleened.Core.ExecPool, strategy: :one_for_one, max_restarts: 0}
      | api_socket_listeners()
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kleened.Core.Supervisor]
    GenServer.stop(pid)

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error,
       {:shutdown,
        {:failed_to_start_child, Kleened.Core.Config, {%RuntimeError{message: msg}, _}}}} ->
        {:error, "could not start kleened: #{msg}"}

      unknown_return ->
        {:error, "could not start kleened: #{inspect(unknown_return)}"}
    end
  end
end
