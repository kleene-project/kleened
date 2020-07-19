defmodule Jocker.Engine.Container do
  defmodule State do
    defstruct container: nil,
              subscribers: nil,
              starting_port: nil
  end

  require Logger
  alias Jocker.Engine.MetaData
  alias Jocker.Engine.Volume
  alias Jocker.Engine.Layer
  import Jocker.Engine.Records
  use GenServer

  @type create_opts() :: [
          {:existing_container, String.t()}
          | {:image, String.t()}
          | {:name, String.t()}
          | {:cmd, [String.t()]}
          | {:user, String.t()}
          | {:jail_param, [String.t()]}
        ]

  ### ===================================================================
  ### API
  ### ===================================================================
  @spec create(create_opts) :: {:ok, Jocker.Engine.Records.container()} | {:error, term()}
  def create(opts) do
    {:ok, pid} =
      DynamicSupervisor.start_child(Jocker.Engine.ContainerPool, Jocker.Engine.Container)

    output =
      case Keyword.get(opts, :existing_container, :none) do
        :none -> GenServer.call(pid, {:create, opts})
        cont -> GenServer.call(pid, {:recreate, cont, opts})
      end

    case output do
      {:error, error} ->
        DynamicSupervisor.terminate_child(Jocker.Engine.ContainerPool, pid)
        error

      success ->
        success
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec attach(pid()) :: :ok
  def attach(pid),
    do: GenServer.call(pid, {:attach, self()})

  @spec metadata(pid()) :: Jocker.Engine.Records.container()
  def metadata(pid),
    do: GenServer.call(pid, :metadata)

  @spec start(pid()) :: :ok
  def start(pid) do
    GenServer.call(pid, :start)
  end

  @spec destroy(String.t()) :: :ok
  def destroy(id) do
    container(pid: pid, layer_id: layer_id) = cont = MetaData.get_container(id)
    layer(dataset: dataset) = MetaData.get_layer(layer_id)

    case pid do
      :none -> :ok
      _ -> stop(pid)
    end

    Volume.destroy_mounts(cont)
    MetaData.delete_container(cont)
    0 = Jocker.Engine.ZFS.destroy(dataset)
    :ok
  end

  def stop(pid) do
    :ok = GenServer.call(pid, :shutdown)
    DynamicSupervisor.terminate_child(Jocker.Engine.ContainerPool, pid)
  end

  ### ===================================================================
  ### gen_server callbacks
  ### ===================================================================

  @impl true
  def init([]) do
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:create, opts}, _from, state) do
    Logger.debug("Creating container with opts: #{inspect(opts)}")
    image_name = Keyword.get(opts, :image, "base")

    case MetaData.get_image(image_name) do
      :not_found ->
        {:reply, {:error, :image_not_found}, state}

      # Extract default values from image:
      image(
        id: image_id,
        user: default_user,
        command: default_cmd,
        layer_id: parent_layer_id
      ) ->
        parent_layer = Jocker.Engine.MetaData.get_layer(parent_layer_id)
        layer(id: layer_id) = Layer.initialize(parent_layer)

        # Extract values from options:
        command = Keyword.get(opts, :cmd, default_cmd)
        user = Keyword.get(opts, :user, default_user)
        jail_param = Keyword.get(opts, :jail_param, [])
        name = Keyword.get(opts, :name, Jocker.Engine.NameGenerator.new())

        cont =
          container(
            id: Jocker.Engine.Utils.uuid(),
            name: name,
            ip: Jocker.Engine.Network.new(),
            pid: self(),
            command: command,
            layer_id: layer_id,
            image_id: image_id,
            user: user,
            # parameters: ["exec.jail_user=" <> user | jail_param],
            parameters: jail_param,
            created: DateTime.to_iso8601(DateTime.utc_now())
          )

        # Mount volumes into container (if any have been provided)
        bind_volumes(opts, cont)

        MetaData.add_container(cont)
        {:reply, {:ok, cont}, %State{container: cont, subscribers: []}}
    end
  end

  def handle_call({:recreate, existing_container, opts}, _from, state) do
    Logger.debug("Re-creating container with opts: #{inspect(opts)}")
    cont = Jocker.Engine.MetaData.get_container(existing_container)

    case cont do
      :not_found ->
        {:reply, {:error, :container_not_found}, state}

      container(user: default_user, command: default_cmd, pid: :none) ->
        command = Keyword.get(opts, :cmd, default_cmd)
        user = Keyword.get(opts, :user, default_user)
        new_cont = container(cont, pid: self(), user: user, command: command)
        {:reply, {:ok, new_cont}, %State{container: new_cont, subscribers: []}}

      container(user: default_user, command: default_cmd) ->
        {:reply, {:already_running, cont}, %State{container: cont, subscribers: []}}
    end
  end

  def handle_call(:shutdown, _from, state) do
    shutdown_container(state)
    {:reply, :ok, %State{}}
  end

  def handle_call({:attach, pid}, _from, %State{subscribers: subscribers} = state) do
    {:reply, :ok, %State{state | subscribers: Enum.uniq([pid | subscribers])}}
  end

  def handle_call(:metadata, _from, %State{container: container} = state) do
    {:reply, container, state}
  end

  def handle_call(:start, _from, %State{:container => container(running: true)} = state) do
    {:reply, :already_started, state}
  end

  def handle_call(:start, _from, %State{:container => container} = state) do
    port = start_(container)
    Logger.info("Succesfully started jail-port: #{inspect(port)}")
    updated_container = container(container, running: true)
    MetaData.add_container(updated_container)
    {:reply, :ok, %State{state | :container => updated_container, :starting_port => port}}
  end

  @impl true
  def handle_info({port, {:data, msg}}, %State{:starting_port => port} = state) do
    Logger.debug("Msg from jail-port: #{inspect(msg)}")
    relay_msg(msg, state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _}}, %State{:starting_port => port} = state) do
    Logger.info("Jail-starting process exited succesfully.")

    case is_jail_running?(state.container) do
      false ->
        shutdown_container(state)
        DynamicSupervisor.terminate_child(Jocker.Engine.ContainerPool, self())
        {:noreply, %State{}}

      true ->
        # Since the jail-starting process is stopped no messages will be sent to Jocker.
        # This happens when, e.g., a full-blow vm-jail has been started (using /etc/rc)
        relay_msg({:shutdown, :end_of_ouput}, state)
        {:noreply, %State{state | :starting_port => nil}}
    end
  end

  def handle_info(unknown_msg, state) do
    Logger.warn("Unknown message: #{inspect(unknown_msg)}")
    {:noreply, state}
  end

  ### ===================================================================
  ### Internal functions
  ### ===================================================================
  defp bind_volumes(options, container) do
    Enum.map(options, fn vol -> bind_volumes_(vol, container) end)
  end

  defp bind_volumes_({:volume, vol_raw}, cont) do
    case String.split(vol_raw, ":") do
      [<<"/", _::binary>> = location] ->
        # anonymous volume
        create_and_bind("", location, [ro: false], cont)

      [<<"/", _::binary>> = location, "ro"] ->
        # anonymous volume - readonly
        create_and_bind("", location, [ro: true], cont)

      [name, location, "ro"] ->
        # named volume - readonly
        create_and_bind(name, location, [ro: true], cont)

      [name, location] ->
        # named volume
        create_and_bind(name, location, [ro: false], cont)
    end
  end

  defp bind_volumes_(_, _cont) do
    :ok
  end

  defp create_and_bind("", location, opts, cont) do
    name = Jocker.Engine.Utils.uuid()
    vol = Volume.create_volume(name)
    Volume.bind_volume(cont, vol, location, opts)
  end

  defp create_and_bind(name, location, opts, cont) do
    vol = MetaData.get_volume(name)
    Volume.bind_volume(cont, vol, location, opts)
  end

  defp relay_msg(msg, state) do
    # Logger.debug("relaying msg: #{inspect(msg)}")
    wrapped_msg = {:container, self(), msg}
    Enum.map(state.subscribers, fn x -> Process.send(x, wrapped_msg, []) end)
  end

  defp start_(
         container(
           id: id,
           layer_id: layer_id,
           command: [cmd | cmd_args],
           ip: ip,
           user: user,
           parameters: parameters
         )
       ) do
    layer(mountpoint: path) = Jocker.Engine.MetaData.get_layer(layer_id)

    args =
      ~w"-c path=#{path} name=#{id} ip4.addr=#{ip}" ++
        parameters ++ ["exec.jail_user=" <> user, "command=#{cmd}"] ++ cmd_args

    Logger.debug("Executing /usr/sbin/jail #{Enum.join(args, " ")}")

    port =
      Port.open(
        {:spawn_executable, '/usr/sbin/jail'},
        [:stderr_to_stdout, :binary, :exit_status, {:args, args}]
      )

    port
  end

  defp shutdown_container(state) do
    container(id: id) = state.container
    Logger.debug("Shutting down jail #{id}")

    if is_jail_running?(state.container) do
      {output, exitcode} = System.cmd("/usr/sbin/jail", ["-r", id], stderr_to_stdout: true)
      Logger.info("Stopped jail #{id} with exitcode #{exitcode}: #{output}")
    end

    jail_cleanup(state.container)

    updated_container =
      container(state.container,
        running: false,
        pid: :none
      )

    MetaData.add_container(updated_container)
    relay_msg({:shutdown, :jail_stopped}, state)
  end

  defp is_jail_running?(container(id: id)) do
    case System.cmd("jls", ["--libxo=json", "-j", id], stderr_to_stdout: true) do
      {_json, 1} -> false
      {_json, 0} -> true
    end
  end

  defp jail_cleanup(container(layer_id: layer_id)) do
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    # remove any devfs mounts of the jail
    {output, _exitcode} = System.cmd("mount", [], stderr_to_stdout: true)
    output |> String.split("\n") |> Enum.map(&umount_container_devfs(&1, mountpoint))
  end

  defp umount_container_devfs(line, mountpoint) do
    devfs_path = Path.join(mountpoint, "dev")

    case String.split(line, " ") do
      ["devfs", "on", ^devfs_path | _rest] ->
        Logger.info("unmounting #{devfs_path}")
        {"", 0} = System.cmd("/sbin/umount", [devfs_path], stderr_to_stdout: true)

      _ ->
        :ok
    end
  end
end
