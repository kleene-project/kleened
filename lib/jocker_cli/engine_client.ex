defmodule Jocker.CLI.EngineClient do
  defmodule State do
    defstruct socket: nil,
              buffer: nil,
              caller: nil
  end

  use GenServer
  require Logger
  alias Jocker.Engine.Config
  alias :gen_tcp, as: GenTCP
  alias :erlang, as: Erlang

  ### ===================================================================
  ### API
  ### ===================================================================
  def start_link([]),
    do: GenServer.start_link(__MODULE__, [self()], name: __MODULE__)

  def command(cmd),
    do: GenServer.call(__MODULE__, {:command, cmd})

  ### ===================================================================
  ### gen_server callbacks
  ### ===================================================================

  @impl true
  def init([callers_pid]) do
    api_socket = Config.get(:api_socket)

    Logger.info("Connecting to jocker-engine")

    case GenTCP.connect({:local, api_socket}, 0, [:binary, {:packet, :raw}, {:active, true}]) do
      {:ok, socket} ->
        Logger.info("Connection succesfully established")
        {:ok, %State{:socket => socket, :caller => callers_pid, :buffer => ""}}

      {:error, reason} ->
        IO.puts("jocker-cli: Error connecting to backed: #{reason}")
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
    Process.send(pid, :tcp_closed, [])
    {:noreply, state}
  end

  def handle_info({:tcp_error, _socket, reason}, %State{caller: pid} = state) do
    Process.send(pid, {:tcp_error, reason}, [])
    {:noreply, state}
  end

  def handle_info({:tcp, _socket, data}, %State{caller: pid, buffer: buffer} = state) do
    case Jocker.Engine.Utils.decode_buffer(buffer <> data) do
      {:no_full_msg, new_buffer} ->
        {:noreply, %State{state | :buffer => new_buffer}}

      {reply, new_buffer} ->
        Logger.debug("Receiving reply from server: #{inspect(reply)}")
        Process.send(pid, {:server_reply, reply}, [])
        {:noreply, %State{state | :buffer => new_buffer}}
    end
  end
end
