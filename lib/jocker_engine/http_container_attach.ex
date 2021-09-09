defmodule Jocker.Engine.HTTPContainerAttach do
  require Logger

  # Called on connection initialization
  def init(req, state) do
    {:cowboy_websocket, req, state, %{idle_timeout: 60000}}
  end

  # Called on websocket connection initialization.
  def websocket_init(state) do
    # FIXME: This is where we should do the call to container attach. The init-function above is called from a different temporary process.
    state = %{}
    {:ok, state}
  end

  # Handle 'ping' messages from the browser - reply
  def websocket_handle({:text, "ping"}, state) do
    {[{:text, "pong"}], state}
  end

  # Handle other messages from the browser - don't reply
  def websocket_handle({:text, message}, state) do
    IO.puts(message)
    {:ok, state}
  end

  # Format and forward elixir messages to client
  def websocket_info(message, state) do
    {[{:text, message}], state}
  end

  # No matter why we terminate, remove all of this pids subscriptions
  def websocket_terminate(_reason, _state) do
    :ok
  end
end
