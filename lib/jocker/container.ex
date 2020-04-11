defmodule Jocker.Container do
  defmodule State do
    defstruct container: nil,
              subscribers: nil,
              starting_port: nil
  end

  import Jocker.Records
  use GenServer

  ### ===================================================================
  ### API
  ### ===================================================================
  def create(opts),
    do: GenServer.start_link(__MODULE__, opts)

  def attach(pid),
    do: GenServer.call(pid, {:attach, self()})

  def metadata(pid),
    do: GenServer.call(pid, :metadata)

  def start(pid) do
    GenServer.call(pid, :start)
  end

  def stop(pid) do
    GenServer.call(pid, :stop)
  end

  ### ===================================================================
  ### gen_server callbacks
  ### ===================================================================

  @impl true
  def init(opts) do
    image(
      id: image_id,
      user: default_user,
      command: default_cmd,
      layer: parent_layer
    ) = Keyword.get(opts, :image, Jocker.MetaData.get_image("base"))

    command = Keyword.get(opts, :cmd, default_cmd)
    user = Keyword.get(opts, :user, default_user)
    jail_param = Keyword.get(opts, :jail_param, [])
    overwrite = Keyword.get(opts, :overwrite, false)

    new_layer =
      case overwrite do
        true -> parent_layer
        false -> Jocker.Layer.initialize(parent_layer)
      end

    container =
      container(
        id: Jocker.Utils.uuid(),
        name: Jocker.NameGenerator.new(),
        ip: Jocker.Network.new(),
        pid: self(),
        command: command,
        layer: new_layer,
        image_id: image_id,
        parameters: ["exec.jail_user=" <> user | jail_param],
        created: :erlang.timestamp()
      )

    Jocker.MetaData.add_container(container)
    {:ok, %State{container: container, subscribers: []}}
  end

  @impl true
  def handle_call({:attach, pid}, _from, %State{subscribers: subscribers} = state) do
    {:reply, :ok, %State{state | subscribers: Enum.uniq([pid | subscribers])}}
  end

  def handle_call(:metadata, _from, %State{container: container} = state) do
    {:reply, container, state}
  end

  def handle_call(:start, _from, %State{:container => container} = state) do
    port = start_(container)
    updated_container = container(container, running: true)
    Jocker.MetaData.add_container(updated_container)
    {:reply, :ok, %State{state | :container => updated_container, :starting_port => port}}
  end

  def handle_call(:stop, _from, state) do
    container(id: id) = state.container
    {_output, _exitcode} = System.cmd("/usr/sbin/jail", ["-r", id])
    reply = :ok
    {:stop, :normal, reply, state}
  end

  @impl true
  def handle_info({port, {:data, msg}}, %State{:starting_port => port} = state) do
    IO.puts("Msg from jail-starting port: #{inspect(msg)}")
    relay_msg(msg, state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _}}, %State{:starting_port => port} = state) do
    IO.puts("Jail-starting process exited succesfully.")

    case is_jail_running?(state.container) do
      false ->
        {:stop, :normal, %State{state | :starting_port => nil}}

      true ->
        # Since the jail-starting process is stopped no messages will be sent to Jocker.
        # This happens when, e.g., a full-blow vm-jail has been started (using /etc/rc)
        relay_msg("end of output", state)
        {:noreply, %State{state | :starting_port => nil}}
    end
  end

  def handle_info({:EXIT, port, reason}, state) do
    IO.puts("Container (port #{inspect(port)}) crashed unexpectedly: #{reason}")
    {:noreply, state}
  end

  def handle_info(unknown_msg, state) do
    IO.puts("Unknown message: #{inspect(unknown_msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    IO.puts("Jail shutting down. Cleaning up.")
    jail_cleanup(state.container)
    relay_msg("jail stopped", state)

    updated_container =
      container(state.container,
        running: false,
        pid: nil
      )

    Jocker.MetaData.add_container(updated_container)
  end

  ### ===================================================================
  ### Internal functions
  ### ===================================================================
  defp relay_msg(msg, state) do
    IO.puts("relaying msg: #{msg}")
    wrapped_msg = {:container, self(), msg}
    Enum.map(state.subscribers, fn x -> Process.send(x, wrapped_msg, []) end)
  end

  defp start_(
         container(
           id: id,
           layer: layer(mountpoint: path),
           command: [cmd | cmd_args],
           ip: ip,
           parameters: parameters
         )
       ) do
    args =
      ~w"-c path=#{path} name=#{id} ip4.addr=#{ip}" ++
        parameters ++ ["command=#{cmd}"] ++ cmd_args

    port =
      Port.open(
        {:spawn_executable, '/usr/sbin/jail'},
        [:binary, :exit_status, {:args, args}]
      )

    port
  end

  defp is_jail_running?(container(id: id)) do
    case System.cmd("jls", ["--libxo=json", "-j", id]) do
      {_json, 1} -> false
      {_json, 0} -> true
    end
  end

  defp jail_cleanup(container(layer: layer(mountpoint: mountpoint))) do
    # remove any devfs mounts of the jail
    {output, _exitcode} = System.cmd("mount", [])
    output |> String.split("\n") |> Enum.map(&umount_container_devfs(&1, mountpoint))
  end

  defp umount_container_devfs(line, mountpoint) do
    devfs_path = Path.join(mountpoint, "dev")

    case String.split(line, " ") do
      ["devfs", "on", ^devfs_path | _rest] ->
        IO.puts("unmounting #{devfs_path}")
        {"", 0} = System.cmd("/sbin/umount", [devfs_path])

      _ ->
        :ok
    end
  end
end
