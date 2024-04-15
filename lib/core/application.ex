defmodule Kleened.Core.Application do
  alias Kleened.Core.{MetaData, Exec}

  @moduledoc false
  require Logger

  use Application

  def start_link() do
    start(nil, nil)
  end

  def start(_type, _args) do
    socket_configurations = Kleened.Core.Config.bootstrap()

    children = [
      Kleened.Core.Config,
      Kleened.Core.MetaData,
      Kleened.Core.Network,
      {Registry, keys: :unique, name: Kleened.Core.ExecInstances},
      {DynamicSupervisor, name: Kleened.Core.ExecPool, strategy: :one_for_one, max_restarts: 0}
      | api_socket_listeners(socket_configurations)
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kleened.Core.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        initialize_containers()
        {:ok, pid}

      {:error,
       {:shutdown,
        {:failed_to_start_child, Kleened.Core.Config, {%RuntimeError{message: msg}, _}}}} ->
        {:error, "could not start kleened: #{msg}"}

      unknown_return ->
        {:error, "could not start kleened: #{inspect(unknown_return)}"}
    end
  end

  def api_socket_listeners(listeners) do
    indexed_listeners = Enum.zip(Enum.to_list(1..length(listeners)), listeners)

    Enum.map(indexed_listeners, fn {index, {scheme, cowboy_options}} ->
      Plug.Cowboy.child_spec(
        scheme: scheme,
        plug: String.to_atom("Listener#{index}"),
        options: [{:dispatch, Kleened.API.Router.dispatch()} | cowboy_options]
      )
    end)
  end

  def initialize_containers() do
    Logger.info("Initializing containers...")

    MetaData.list_containers()
    |> Enum.filter(&(&1.restart_policy == "on-startup"))
    |> Enum.map(fn container ->
      with {:ok, exec_id} <- Exec.create(container.id),
           :ok <- Exec.start(exec_id, %{attach: true, start_container: true}) do
        Logger.debug("Succesfully starting container #{container.id}")
      else
        {:error, reason} -> Logger.warning("Could not start container #{container.id}: #{reason}")
      end
    end)
  end

  Logger.info("Done initializing containers!")
end
