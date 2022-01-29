defmodule Jocker.Engine.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false
  require Logger

  use Application

  def start_link() do
    start(nil, nil)
  end

  def start(_type, _args) do
    # FIXME: This is a dirty-hack to fetch "api_socket" before supervisor is started, as it is used to configure ranch supervisor.
    # To make this properly requires a refactor of the Jocker.Engine.Config:
    # Load the configuration file at startup and pass configuration parameters in the child
    # in the supervision-tree here: The configuration values are required here before supervisor i started.
    {:ok, pid} = Jocker.Engine.Config.start_link([])
    # socket_opts = create_socket_options(Jocker.Engine.Config.get("api_socket"))
    GenServer.stop(pid)

    children = [
      Jocker.Engine.Config,
      Jocker.Engine.MetaData,
      Jocker.Engine.Layer,
      Jocker.Engine.Network,
      {Registry, keys: :unique, name: Registry.ExecInstances},
      {DynamicSupervisor,
       name: Jocker.Engine.ContainerPool, strategy: :one_for_one, max_restarts: 0},
      {Plug.Cowboy,
       scheme: :http,
       plug: HTTP.API,
       options: [port: 8085, dispatch: Jocker.API.Router.dispatch()]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Jocker.Engine.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error,
       {:shutdown,
        {:failed_to_start_child, Jocker.Engine.Config, {%RuntimeError{message: msg}, _}}}} ->
        {:error, "could not start dockerd: #{msg}"}

      unknown_return ->
        msg = "could not start jockerd: #{inspect(unknown_return)}"
        Logger.error(msg)
        {:error, msg}
    end
  end

  defp create_socket_options(api_socket) do
    case api_socket do
      {:unix, path, port} ->
        File.rm(path)
        [{:port, port}, {:ip, {:local, path}}]

      {_iptype, address, port} ->
        [{:port, port}, {:ip, address}]
    end
  end
end
