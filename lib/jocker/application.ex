defmodule Jocker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      # Starts a worker by calling: JockTMod.Worker.start_link(arg)
      Jocker.MetaData,
      Jocker.Layer,
      {Jocker.Network, [{"10.13.37.1", "10.13.37.255"}, "jocker0"]},
      Jocker.ContainerPool
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Jocker.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
