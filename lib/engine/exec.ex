defmodule Jocker.Engine.Exec do
  alias Jocker.API.Schemas.ExecConfig
  alias Jocker.Engine.{MetaData, Volume, Layer, Network, Image, Utils, ExecInstances}

  defmodule State do
    defstruct config: nil,
              exec_id: nil,
              subscribers: nil,
              port: nil
  end

  alias __MODULE__, as: Exec
  use GenServer, restart: :transient

  # Todos:
  # - Need to create a "exec_instance" table in MetaData
  #   - it needs to store exec config + is-it-the-jail-starting-exec
  # questions:
  # - You can attach to a exec instance before it is started.
  #   Where do we store info about processes that wants to received io-data,
  #   before the process is started? In the metadata?
  #   two possible solutions:
  #    - Store the pid somewhere where it can be fetched by exec_start process
  #    - merge start and attach into one call (which is then going to use a ws in case it needs to be attached)

  @type execution_config() :: %ExecConfig{}

  @type exec_id() :: String.t()

  @spec create(execution_config()) :: {:ok, exec_id()} | {:error, String.t()}
  def create(config) do
    exec_id = Utils.uuid()
    name = {:via, Registry, {ExecInstances, exec_id, config.container_id}}
    {:ok, _pid} = GenServer.start_link(Jocker.Engine.Exec, [exec_id, config], name: name)
    exec_id
  end

  @spec start(exec_id()) :: :ok | {:error, String.t()}
  def start(exec_id, %{:attach => attach}) do
    case Registry.lookup(ExecInstances, exec_id) do
      [{pid, _container_id}] ->
        GenServer.call(pid, :start)

      [] ->
        {:error, "could not find a execution instance matching #{exec_id}"}
    end
  end

  @spec stop(exec_id()) :: :ok | {:error, String.t()}
  def stop(exec_id) do
    case Registry.lookup(ExecInstances, exec_id) do
      [{pid, _container_id}] ->
        GenServer.call(pid, :stop)

      [] ->
        {:error, "could not find a execution instance matching #{exec_id}"}
    end
  end

  ### ===================================================================
  ### gen_server callbacks
  ### ===================================================================
  @impl true
  def init([exec_id, config]) do
    {:ok, %State{exec_id: exec_id, config: config, subscribers: []}}
  end

  @impl true
  def handle_call(:stop, _from, %State{port: nil} = state) do
    # - lookup exec instance
    # - stop it (but not stopping the jail
    {:reply, {:error, "already stopped"}, state}
  end

  def handle_call(:stop, _from, %State{port: port} = state) do
    Port.close(port)
    {:reply, :ok, state}
  end

  def handle_call({:attach, pid}, _from, %State{subscribers: subscribers} = state) do
    {:reply, :ok, %State{state | subscribers: Enum.uniq([pid | subscribers])}}
  end

  def handle_call(:start, _from, state) do
    # - verify if jail is running or not
    # - check if it is already executing (i.e., lookup in registry)
    # - start it, if it is not already started

    # - lookup container
    # - merge container-conf with the conf supplied here
    # - generate id and save metadata
    case start_(state.config) do
      {:error, _reason} = msg ->
        {:reply, msg, state}

      {:ok, port} when is_port(port) ->
        {:reply, :ok, %State{state | :port => port}}
    end
  end

  @impl true
  def handle_info({port, {:data, jail_output}}, %State{:port => port} = state) do
    Logger.debug("#{inspect(port)} Msg from executing port: #{inspect(jail_output)}")
    relay_msg({:jail_output, jail_output}, state)
    {:noreply, state}
  end

  def handle_info(
        {port, {:exit_status, exit_code}},
        %State{port: port, config: config} = state
      ) do
    case is_jail_running?(config.container_id) do
      false ->
        jail_cleanup(cont)

        Logger.debug(
          "container #{inspect(config.container_id)} stopped with exit code #{exit_code}"
        )

        relay_msg({:shutdown, :jail_stopped}, state)

      true ->
        Logger.debug(
          "execution instance #{inspect(state.exec_id)} stopped with exit code #{exit_code}"
        )

        # FIXME rename atom :jail_root_process_exited
        relay_msg({:shutdown, :jail_root_process_exited}, state)
    end

    {:stop, :shutdown, %State{state | :starting_port => nil}}
  end

  def handle_info(unknown_msg, state) do
    Logger.warn("Unknown message: #{inspect(unknown_msg)}")
    {:noreply, state}
  end

  defp is_jail_running?(container_id) do
    output = System.cmd("jls", ["--libxo=json", "-j", container_id], stderr_to_stdout: true)

    case output do
      {_json, 1} -> false
      {_json, 0} -> true
    end
  end
end
