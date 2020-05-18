defmodule Jocker.Engine.Container do
  defmodule State do
    defstruct container: nil,
              subscribers: nil,
              starting_port: nil
  end

  require Logger
  alias Jocker.Engine.MetaData
  import Jocker.Engine.Records
  use GenServer

  @type create_opts() :: [
          {:id_or_name, String.t()}
          | {:image, Jocker.Engine.Records.container()}
          | {:name, String.t()}
          | {:cmd, [String.t()]}
          | {:user, String.t()}
          | {:jail_param, [String.t()]}
          | {:overwrite, boolean()}
        ]

  ### ===================================================================
  ### API
  ### ===================================================================
  @spec create(create_opts) :: GenServer.on_start()
  def create(opts),
    do: GenServer.start_link(__MODULE__, opts)

  @spec attach(pid()) :: :ok
  def attach(pid),
    do: GenServer.call(pid, {:attach, self()})

  def metadata(pid),
    do: GenServer.call(pid, :metadata)

  @spec start(pid()) :: :ok
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
    Keyword.get(opts, :id_or_name, :none)

    case Keyword.get(opts, :id_or_name, :none) do
      :none ->
        image_name = Keyword.get(opts, :image, "base")
        img = MetaData.get_image(image_name)

        case img do
          :not_found ->
            {:stop, :normal, :image_not_found}

          _image ->
            # Extract default values from image:
            image(
              id: image_id,
              user: default_user,
              command: default_cmd,
              layer_id: parent_layer_id
            ) = img

            parent_layer = Jocker.Engine.MetaData.get_layer(parent_layer_id)

            # Extract values from options:
            command = Keyword.get(opts, :cmd, default_cmd)
            user = Keyword.get(opts, :user, default_user)
            jail_param = Keyword.get(opts, :jail_param, [])
            overwrite = Keyword.get(opts, :overwrite, false)
            name = Keyword.get(opts, :name, Jocker.Engine.NameGenerator.new())

            layer(id: new_layer_id) =
              case overwrite do
                true -> parent_layer
                false -> Jocker.Engine.Layer.initialize(parent_layer)
              end

            cont =
              container(
                id: Jocker.Engine.Utils.uuid(),
                name: name,
                ip: Jocker.Engine.Network.new(),
                pid: self(),
                command: command,
                layer_id: new_layer_id,
                image_id: image_id,
                parameters: ["exec.jail_user=" <> user | jail_param],
                created: DateTime.to_iso8601(DateTime.utc_now())
              )

            MetaData.add_container(cont)
            {:ok, %State{container: cont, subscribers: []}}
        end

      id_or_name ->
        case Jocker.Engine.MetaData.get_container(id_or_name) do
          :not_found ->
            {:stop, :normal, :container_not_found}

          cont ->
            # MetaData.add_container(cont)
            {:ok, %State{container: cont, subscribers: []}}
        end
    end
  end

  @impl true
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
    updated_container = container(container, running: true)
    MetaData.add_container(updated_container)
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
    IO.puts("Msg from jail-port: #{inspect(msg)}")
    relay_msg(msg, state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _}}, %State{:starting_port => port} = state) do
    Logger.info("Jail-starting process exited succesfully.")

    case is_jail_running?(state.container) do
      false ->
        {:stop, :normal, %State{state | :starting_port => nil}}

      true ->
        # Since the jail-starting process is stopped no messages will be sent to Jocker.
        # This happens when, e.g., a full-blow vm-jail has been started (using /etc/rc)
        relay_msg({:shutdown, :end_of_ouput}, state)
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
    relay_msg({:shutdown, :jail_stopped}, state)

    updated_container =
      container(state.container,
        running: false,
        pid: nil
      )

    MetaData.add_container(updated_container)
  end

  ### ===================================================================
  ### Internal functions
  ### ===================================================================
  defp relay_msg(msg, state) do
    IO.puts("relaying msg: #{inspect(msg)}")
    wrapped_msg = {:container, self(), msg}
    Enum.map(state.subscribers, fn x -> Process.send(x, wrapped_msg, []) end)
  end

  defp start_(
         container(
           id: id,
           layer_id: layer_id,
           command: [cmd | cmd_args],
           ip: ip,
           parameters: parameters
         )
       ) do
    layer(mountpoint: path) = Jocker.Engine.MetaData.get_layer(layer_id)

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

  defp jail_cleanup(container(layer_id: layer_id)) do
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
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
