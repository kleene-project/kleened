defmodule Jocker.CLI.Config do
  use Agent

  # @default_socket "unix:///var/run/jocker.sock"
  @default_socket "tcp://127.0.0.1:8000"

  def start_link(opts) do
    Agent.start_link(fn -> initialize(opts) end, name: __MODULE__)
  end

  def get(key, default \\ nil) do
    Agent.get(__MODULE__, &Map.get(&1, key, default))
  end

  def put(key, value) do
    Agent.update(__MODULE__, &Map.put(&1, key, value))
  end

  def delete(key) do
    Agent.update(__MODULE__, &Map.delete(&1, key))
  end

  defp initialize([:default]) do
    initialize(host: @default_socket)
  end

  defp initialize(opts) do
    debug =
      case Keyword.get(opts, :debug) do
        true -> Logger.configure(level: :debug)
        _ -> :ok
      end

    host = Keyword.get(opts, :host, @default_socket)
    host = Jocker.Engine.Utils.decode_socket_address(host)
    %{:host => host, :debug => debug}
  end
end
