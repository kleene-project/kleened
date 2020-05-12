defmodule Jocker.Engine.APIServer do
  defmodule State do
    defstruct api_socket: nil,
              sockets: nil,
              buffers: nil
  end

  require Jocker.Engine.Config
  require Logger
  use GenServer
  alias :gen_tcp, as: GenTCP
  alias :erlang, as: Erlang

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    Logger.info("jocker-engine: Initating API backed")
    api_socket = Jocker.Engine.Config.api_socket()
    File.rm(api_socket)

    {:ok, listening_socket} =
      GenTCP.listen(0, [
        :binary,
        {:packet, :raw},
        {:active, false},
        {:ip, {:local, api_socket}}
      ])

    Logger.info("jocker-engine: Listening on #{api_socket}")
    server_pid = self()
    _listener_pid = Process.spawn(fn -> listen(server_pid, listening_socket) end, [:link])

    {:ok, %State{:api_socket => listening_socket, :sockets => %{}, :buffers => %{}}}
  end

  @impl true
  def handle_info({:client_connected, socket}, state) do
    updated_buffers = Map.put(state.buffers, socket, "")
    {:noreply, %State{state | :buffers => updated_buffers}}
  end

  def handle_info({:tcp_closed, socket}, %State{buffers: buffers} = state) do
    new_buffers = Map.delete(buffers, socket)
    {:noreply, %State{state | :buffers => new_buffers}}
  end

  def handle_info({:tcp_error, socket, _reason}, %State{buffers: buffers} = state) do
    new_buffers = Map.delete(buffers, socket)
    {:noreply, %State{state | :buffers => new_buffers}}
  end

  def handle_info({:tcp, socket, data}, state) do
    # Logger.debug("receiving data")
    buffer = Map.get(state.buffers, socket)

    case Jocker.Engine.Utils.decode_buffer(buffer <> data) do
      {:no_full_msg, new_buffer} ->
        updated_buffers = Map.put(state.buffers, socket, new_buffer)
        {:noreply, %State{state | :buffers => updated_buffers}}

      {[Jocker.Engine.ContainerPool, :create, _] = command, new_buffer} ->
        reply = evaluate_command(command)
        updated_buffers = Map.put(state.buffers, socket, new_buffer)

        new_state =
          case reply do
            {:ok, pid} ->
              sockets = Map.put(state.sockets, pid, socket)
              %State{state | :buffers => updated_buffers, :sockets => sockets}

            some_error ->
              %State{state | :buffers => updated_buffers}
          end

        GenTCP.send(socket, Erlang.term_to_binary(reply))
        {:noreply, new_state}

      {command, new_buffer} ->
        Logger.debug("decoded command #{inspect(command)}")
        reply = evaluate_command(command)
        GenTCP.send(socket, Erlang.term_to_binary(reply))
        updated_buffers = Map.put(state.buffers, socket, new_buffer)
        {:noreply, %State{state | :buffers => updated_buffers}}
    end
  end

  def handle_info({:container, pid, _msg} = container_msg, state) do
    Logger.debug("Receiving message from container: #{inspect(container_msg)}")
    socket = state.sockets[pid]
    GenTCP.send(socket, Erlang.term_to_binary(container_msg))
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warn("Unknown message received #{inspect(msg)}")
    {:noreply, state}
  end

  defp evaluate_command([module, function, args]) do
    :erlang.apply(module, function, args)
  end

  defp listen(server_pid, listening_socket) do
    case GenTCP.accept(listening_socket) do
      {:ok, socket} ->
        Logger.info("Incoming connection: #{inspect(socket)}")
        GenTCP.controlling_process(socket, server_pid)
        :inet.setopts(socket, [{:active, true}])
        :ok = Process.send(server_pid, {:client_connected, socket}, [])
        listen(server_pid, listening_socket)

      {:error, reason} ->
        Logger.error("API-server crashed: #{reason}")
        exit(:normal)
    end
  end
end
