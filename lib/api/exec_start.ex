defmodule Jocker.API.ExecStartWebSocket do
  alias Jocker.Engine.Exec
  require Logger

  # Called on connection initialization
  def init(%{bindings: %{exec_id: exec_id}} = req0, _opts) do
    opts =
      :cowboy_req.parse_qs(req0)
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> {key, string2bool(value)} end)

    case opts do
      # Everything should be good, proceed with the websocket!
      [{"attach", attach}, {"start_container", start_container}]
      when is_boolean(attach) and is_boolean(start_container) ->
        state = %{
          request: req0,
          attach: attach,
          start_container: start_container,
          exec_id: exec_id
        }

        {:cowboy_websocket, req0, state, %{idle_timeout: 60000}}

      _invalid_parameter_tuple ->
        msg = "invalid value/missing parameter(s)"
        req = :cowboy_req.reply(400, %{"content-type" => "text/plain"}, msg, req0)
        {:ok, req, %{}}
    end
  end

  defp string2bool("true") do
    true
  end

  defp string2bool("false") do
    false
  end

  defp string2bool(invalid) do
    invalid
  end

  # Called on websocket connection initialization.
  def websocket_init(
        %{exec_id: exec_id, attach: attach, start_container: start_container} = state
      ) do
    case Exec.start(exec_id, %{attach: attach, start_container: start_container}) do
      :ok ->
        case attach do
          true ->
            Logger.debug("succesfully started executable #{exec_id}. Await output.")
            {[{:text, "OK"}], state}

          false ->
            Logger.debug("succesfully started executable #{exec_id}. Close websocket.")
            {[{:close, 1001, ""}], state}
        end

      {:error, msg} ->
        Logger.debug("could not start attached executable #{exec_id}: #{msg}")
        {[{:close, 1000, msg}], state}
    end
  end

  def websocket_handle({:text, "ping"}, state) do
    # ping messages should be handled by cowboy
    {:ok, state}
  end

  def websocket_handle({:text, _message}, state) do
    # Ignore messages from the client (i.e. no interactive possibility atm.
    Logger.debug("Received input from client. Cannot handle this yet.")
    {:ok, state}
  end

  def websocket_handle(msg, state) do
    # Ignore messages from the client (i.e. no interactive possibility atm.
    Logger.warn("Unknown message received: #{inspect(msg)}")
    {:ok, state}
  end

  def websocket_info({:container, exec_id, {:shutdown, :jail_stopped}}, state) do
    {[{:close, 1000, "executable #{exec_id} stopped"}], state}
  end

  def websocket_info({:container, exec_id, {:shutdown, :jailed_process_exited}}, state) do
    {[{:close, 1001, "container #{exec_id}'s root process exited"}], state}
  end

  def websocket_info({:container, _container_id, {:jail_output, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info(message, state) do
    Logger.warn("unknown message received: #{inspect(message)}")
    {:ok, state}
  end

  # No matter why we terminate, remove all of this pids subscriptions
  def websocket_terminate(reason, _state) do
    Logger.info("websocket terminated: #{inspect(reason)}")
    :ok
  end
end
