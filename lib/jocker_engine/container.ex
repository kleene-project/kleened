defmodule Jocker.Engine.Container do
  defmodule State do
    defstruct container_id: nil,
              subscribers: nil,
              starting_port: nil
  end

  @derive Jason.Encoder
  defstruct id: "",
            name: "",
            pid: "",
            command: [],
            layer_id: "",
            image_id: "",
            user: "",
            parameters: [],
            env_vars: [],
            created: ""

  alias __MODULE__, as: Container

  require Logger
  alias Jocker.Engine.{MetaData, Volume, Layer, Network, Image}
  use GenServer

  @type t() ::
          %Container{
            id: String.t(),
            name: String.t(),
            pid: pid() | String.t(),
            command: [String.t()],
            layer_id: String.t(),
            image_id: String.t(),
            user: String.t(),
            parameters: [String.t()],
            env_vars: [String.t()],
            created: String.t()
          }

  @type create_opts() :: [
          {:existing_container, String.t()}
          | {:image, String.t()}
          | {:name, String.t()}
          | {:cmd, [String.t()]}
          | {:user, String.t()}
          | {:env, [String.t()]}
          | {:networks, [String.t()]}
          | {:jail_param, [String.t()]}
        ]

  @type list_containers_opts :: [
          {:all, boolean()}
        ]

  @type container_id() :: String.t()

  @type id_or_name() :: container_id() | String.t()

  ### ===================================================================
  ### API
  ### ===================================================================
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec create(create_opts) :: {:ok, Container.t()} | :image_not_found
  def create(options) do
    Logger.debug("Creating container with opts: #{inspect(options)}")
    image = MetaData.get_image(Keyword.get(options, :image, "base"))
    create_(image, options)
  end

  @spec start(id_or_name()) :: {:ok, Container.t()} | {:error, :not_found}
  def start(id_or_name, opts \\ []) do
    cont = MetaData.get_container(id_or_name)

    case spawn_container(cont) do
      {:ok, pid} -> GenServer.call(pid, {:start, cont, opts})
      other -> other
    end
  end

  @spec stop(id_or_name()) ::
          {:ok, %Container{}} | {:error, :not_found} | {:error, :not_running}
  def stop(id_or_name) do
    %Container{id: contaier_id} = cont = MetaData.get_container(id_or_name)

    case is_running?(contaier_id) do
      false ->
        {:error, :not_running}

      true ->
        case spawn_container(cont) do
          {:ok, pid} ->
            reply = GenServer.call(pid, {:stop, cont})
            DynamicSupervisor.terminate_child(Jocker.Engine.ContainerPool, pid)
            reply

          other ->
            other
        end
    end
  end

  @spec destroy(id_or_name()) :: :ok | {:error, :not_found}
  def destroy(id_or_name) do
    cont = MetaData.get_container(id_or_name)
    destroy_(cont)
  end

  @spec list([list_containers_opts()]) :: [%{}]
  def list(options \\ []) do
    list_(options)
  end

  @spec attach(id_or_name()) :: :ok | {:error, :not_found}
  def attach(id_or_name) do
    cont = MetaData.get_container(id_or_name)

    case spawn_container(cont) do
      {:ok, pid} -> GenServer.call(pid, {:attach, self()})
      other -> other
    end
  end

  ### ===================================================================
  ### gen_server callbacks
  ### ===================================================================
  @impl true
  def init([%Container{id: id} = cont]) do
    updated_cont = %Container{cont | pid: self()}
    MetaData.add_container(updated_cont)
    {:ok, %State{container_id: id, subscribers: []}}
  end

  @impl true
  def handle_call({:stop, cont}, _from, state) do
    {:reply, stop_(cont, state), state}
  end

  def handle_call({:attach, pid}, _from, %State{subscribers: subscribers} = state) do
    {:reply, :ok, %State{state | subscribers: Enum.uniq([pid | subscribers])}}
  end

  def handle_call({:start, cont, options}, _from, state) do
    case is_running?(state.container_id) do
      true ->
        {:reply, :already_started, state}

      false ->
        port = start_(options, cont)
        {:reply, {:ok, cont}, %State{state | :starting_port => port}}
    end
  end

  @impl true
  def handle_info({port, {:data, msg}}, %State{:starting_port => port} = state) do
    Logger.debug("Msg from jail-port: #{inspect(msg)}")
    relay_msg(msg, state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _}}, %State{:starting_port => port} = state) do
    Logger.debug("Jail-starting process exited succesfully.")

    cont = MetaData.get_container(state.container_id)

    case is_running?(state.container_id) do
      false ->
        shutdown_container(cont, state)
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
  defp create_(:not_found, _), do: :image_not_found

  defp create_(
         %Image{
           id: image_id,
           user: default_user,
           command: default_cmd,
           layer_id: parent_layer_id,
           env_vars: img_env_vars
         },
         opts
       ) do
    container_id = Jocker.Engine.Utils.uuid()

    parent_layer = Jocker.Engine.MetaData.get_layer(parent_layer_id)
    %Layer{id: layer_id} = Layer.new(parent_layer, container_id)

    # Extract values from options:
    command = Keyword.get(opts, :cmd, default_cmd)
    user = Keyword.get(opts, :user, default_user)
    jail_param = Keyword.get(opts, :jail_param, [])
    name = Keyword.get(opts, :name, Jocker.Engine.NameGenerator.new())
    env_vars = Keyword.get(opts, :env, []) ++ img_env_vars

    network_idnames =
      Keyword.get(opts, :networks, [Jocker.Engine.Config.get("default_network_name")])

    cont = %Container{
      id: container_id,
      name: name,
      command: command,
      layer_id: layer_id,
      image_id: image_id,
      user: user,
      parameters: jail_param,
      env_vars: env_vars,
      created: DateTime.to_iso8601(DateTime.utc_now())
    }

    # Mount volumes into container (if any have been provided)
    bind_volumes(opts, cont)

    # Store new container and connect to the networks
    MetaData.add_container(cont)
    Enum.map(network_idnames, &Network.connect(container_id, &1))
    {:ok, MetaData.get_container(container_id)}
  end

  defp start_(
         options,
         %Container{
           id: id,
           layer_id: layer_id,
           command: default_cmd,
           user: default_user,
           parameters: parameters,
           env_vars: env_vars
         } = cont
       ) do
    command = Keyword.get(options, :cmd, default_cmd)
    user = Keyword.get(options, :user, default_user)
    MetaData.add_container(%Container{cont | user: user, command: command})

    network_config =
      case MetaData.connected_networks(id) do
        ["host"] ->
          "ip4=inherit"

        network_ids ->
          ips = Enum.reduce(network_ids, [], &extract_ips(id, &1, &2))
          ips_as_string = Enum.join(ips, ",")
          "ip4.addr=#{ips_as_string}"
      end

    %Layer{mountpoint: path} = Jocker.Engine.MetaData.get_layer(layer_id)

    args =
      ~w"-c path=#{path} name=#{id} #{network_config}" ++
        parameters ++
        ~w"exec.jail_user=#{user} command=/usr/bin/env -i" ++ env_vars ++ command

    Logger.debug("Executing /usr/sbin/jail #{Enum.join(args, " ")}")

    port =
      Port.open(
        {:spawn_executable, '/usr/sbin/jail'},
        [:stderr_to_stdout, :binary, :exit_status, {:args, args}]
      )

    Logger.info("Succesfully started jail-port: #{inspect(port)}")
    port
  end

  defp stop_(:not_found, _state), do: {:error, :not_found}

  defp stop_(cont, state) do
    case is_running?(state.container_id) do
      true ->
        shutdown_container(cont, state)
        {:ok, cont}

      false ->
        {:error, :not_running}
    end
  end

  defp destroy_(:not_found), do: {:error, :not_found}

  defp destroy_(%Container{id: container_id, pid: pid, layer_id: layer_id} = cont) do
    case pid do
      "" -> :ok
      _ -> stop(container_id)
    end

    Network.disconnect_all(container_id)
    Volume.destroy_mounts(cont)
    MetaData.delete_container(container_id)
    Layer.destroy(layer_id)
    :ok
  end

  @spec list_([list_containers_opts()]) :: [%{}]
  defp list_(options) do
    active_jails = MapSet.new(running_jails())

    containers =
      Enum.map(
        MetaData.list_containers(),
        &Map.put(&1, :running, MapSet.member?(active_jails, &1[:id]))
      )

    case Keyword.get(options, :all, false) do
      true -> containers
      false -> Enum.filter(containers, & &1[:running])
    end
  end

  @spec spawn_container(%Container{} | :not_found) :: {:ok, pid()} | {:error, :not_found}
  defp spawn_container(:not_found), do: {:error, :not_found}

  defp spawn_container(%Container{pid: ""} = cont) do
    DynamicSupervisor.start_child(
      Jocker.Engine.ContainerPool,
      {Jocker.Engine.Container, [cont]}
    )
  end

  defp spawn_container(%Container{pid: pid}) do
    {:ok, pid}
  end

  defp shutdown_container(%Container{id: id} = cont, state) do
    Logger.debug("Shutting down jail #{id}")

    if is_running?(id) do
      {output, exitcode} = System.cmd("/usr/sbin/jail", ["-r", id], stderr_to_stdout: true)
      Logger.info("Stopped jail #{id} with exitcode #{exitcode}: #{output}")
    end

    jail_cleanup(cont)
    updated_container = %Container{cont | pid: ""}
    MetaData.add_container(updated_container)
    relay_msg({:shutdown, :jail_stopped}, state)
  end

  def extract_ips(container_id, network_id, ip_list) do
    config = MetaData.get_endpoint_config(container_id, network_id)
    Enum.concat(config.ip_addresses, ip_list)
  end

  def is_running?(container_id) do
    case System.cmd("jls", ["--libxo=json", "-j", container_id], stderr_to_stdout: true) do
      {_json, 1} -> false
      {_json, 0} -> true
    end
  end

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
    wrapped_msg = {:container, state.container_id, msg}
    Enum.map(state.subscribers, fn x -> Process.send(x, wrapped_msg, []) end)
  end

  def running_jails() do
    {jails_json, 0} = System.cmd("jls", ["-v", "--libxo=json"], stderr_to_stdout: true)
    {:ok, jails} = Jason.decode(jails_json)
    jails = Enum.map(jails["jail-information"]["jail"], & &1["name"])
    jails
  end

  defp jail_cleanup(%Container{layer_id: layer_id}) do
    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)

    # remove any devfs mounts of the jail. If it was closed with 'jail -r <jailname>' devfs should be removed automatically.
    # If the jail stops because there jailed process stops (i.e. 'jail -c <etc> /bin/sleep 10') then devfs is NOT removed.
    # A race condition can also occur such that "jail -r" does not unmount before this call to mount.
    {output, _exitcode} = System.cmd("mount", ["-t", "devfs"], stderr_to_stdout: true)
    output |> String.split("\n") |> Enum.map(&umount_container_devfs(&1, mountpoint))
  end

  defp umount_container_devfs(line, mountpoint) do
    devfs_path = Path.join(mountpoint, "dev")

    case String.split(line, " ") do
      ["devfs", "on", ^devfs_path | _rest] ->
        {msg, n} = System.cmd("/sbin/umount", [devfs_path], stderr_to_stdout: true)
        Logger.info("unmounting #{devfs_path} with status code #{n} and msg #{msg}")

      _ ->
        :ok
    end
  end
end
