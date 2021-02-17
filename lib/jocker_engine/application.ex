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
    children = [
      Jocker.Engine.Config,
      Jocker.Engine.MetaData,
      Jocker.Engine.Layer,
      Jocker.Engine.Network,
      {DynamicSupervisor,
       name: Jocker.Engine.ContainerPool, strategy: :one_for_one, max_restarts: 0},
      Jocker.Engine.APIServer
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
end
