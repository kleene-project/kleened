defmodule Jocker.CLI.EngineClient do
  defmodule State do
    defstruct socket: nil,
              buffer: nil,
              caller: nil
  end

  use GenServer
  require Logger
  alias Jocker.CLI.Config
  alias :gen_tcp, as: GenTCP
  alias :erlang, as: Erlang

  ### ===================================================================
  ### API
  ### ===================================================================
  def start_link([]) do
    GenServer.start_link(__MODULE__, [self()], name: __MODULE__)
  end

  def command(cmd) do
    GenServer.call(__MODULE__, {:command, cmd})
  end

  ### ===================================================================
  ### gen_server callbacks
  ### ===================================================================

  @impl true
  def init([callers_pid]) do
    Logger.info("Connecting to jocker-engine")

    {port, address} = server_location()

    case GenTCP.connect(address, port, [:binary, {:active, :once}]) do
      {:ok, socket} ->
        Logger.info("Connection succesfully established")
        {:ok, %State{:socket => socket, :caller => callers_pid, :buffer => ""}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:command, cmd}, _from, %State{socket: socket} = state) do
    Logger.info("Sending command to jocker-engine #{inspect(cmd)}")
    cmd_binary = Erlang.term_to_binary(cmd)

    case GenTCP.send(socket, cmd_binary) do
      :ok ->
        Logger.debug("Succesfully sent")
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.warn("Error sending msg: #{reason}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, %State{caller: pid} = state) do
    Logger.info("Connection to to jocker-engine closed.")
    Process.send(pid, :tcp_closed, [])
    {:noreply, %State{state | :socket => nil, :buffer => ""}}
  end

  def handle_info({:tcp_error, _socket, reason}, %State{caller: pid} = state) do
    Logger.warn("Connection-error occured: #{inspect(reason)}")
    Process.send(pid, {:tcp_error, reason}, [])
    {:noreply, state}
  end

  def handle_info({:tcp, socket, data}, %State{caller: pid, buffer: buffer} = state) do
    case Jocker.Engine.Utils.decode_buffer(buffer <> data) do
      {:no_full_msg, new_buffer} ->
        :inet.setopts(socket, [{:active, :once}])
        {:noreply, %State{state | :buffer => new_buffer}}

      {reply, new_buffer} ->
        Logger.debug("Receiving reply from server: #{inspect(reply)}")
        Process.send(pid, {:server_reply, reply}, [])

        case reply do
          {:image_builder, _pid, {:image_finished, _img}} -> GenTCP.close(socket)
          {:container, _id, {:shutdown, :jail_stopped}} -> GenTCP.close(socket)
          _ -> :inet.setopts(socket, [{:active, :once}])
        end

        {:noreply, %State{state | :buffer => new_buffer}}
    end
  end

  defp server_location() do
    case Config.get(:host) do
      {:unix, path, port} ->
        {port, {:local, path}}

      {_iptype, address, port} ->
        {port, address}
    end
  end
end
