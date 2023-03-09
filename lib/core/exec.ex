defmodule Kleened.Core.Exec do
  alias Kleened.Core.{Container, MetaData, OS, FreeBSD, Layer, Utils, ExecInstances, Network}
  alias Network.EndPoint
  alias Kleened.API.Schemas

  defmodule State do
    defstruct config: nil,
              exec_id: nil,
              subscribers: nil,
              container: :not_started,
              port: nil
  end

  require Logger
  use GenServer, restart: :transient

  @type execution_config() :: %Schemas.ExecConfig{}
  @type start_options() :: %{:attach => boolean(), :start_container => boolean()}
  @type stop_options() :: %{:force_stop => boolean(), :stop_container => boolean()}
  @type container() :: %Schemas.Container{}

  @type exec_id() :: String.t()
  @type container_id() :: String.t()

  @spec create(execution_config() | container_id()) :: {:ok, exec_id()} | {:error, String.t()}
  def create(container_id) when is_binary(container_id) do
    config = %Schemas.ExecConfig{container_id: container_id, cmd: [], env: [], user: ""}
    create(config)
  end

  def create(%Schemas.ExecConfig{container_id: container_idname} = config) do
    exec_id = Utils.uuid()

    case MetaData.get_container(container_idname) do
      %Schemas.Container{id: container_id} ->
        config = %Schemas.ExecConfig{config | container_id: container_id}

        child_spec = %{
          id: Kleened.Core.Exec,
          start: {GenServer, :start_link, [Kleened.Core.Exec, [exec_id, config]]},
          restart: :temporary,
          shutdown: 10_000
        }

        DynamicSupervisor.start_child(Kleened.Core.ExecPool, child_spec)
        Logger.debug("succesfully created new execution instance #{exec_id}")
        {:ok, exec_id}

      :not_found ->
        {:error, "conntainer not found"}
    end
  end

  @spec start(exec_id(), start_options()) :: :ok | {:error, String.t()}
  def start(exec_id, opts) do
    if opts.attach do
      call(exec_id, {:attach, self()})
    end

    call(exec_id, {:start, opts})
  end

  @spec stop(exec_id(), stop_options) :: {:ok, String.t()} | {:error, String.t()}
  def stop(exec_id, opts) do
    call(exec_id, {:stop, opts})
  end

  @spec send(exec_id(), String.t()) :: :ok | {:error, String.t()}
  def send(exec_id, data) do
    case Registry.lookup(ExecInstances, exec_id) do
      [{pid, _container_id}] ->
        Process.send(pid, {self(), {:input_data, data}}, [])

      [] ->
        {:error, "could not find a execution instance matching '#{exec_id}'"}
    end
  end

  @spec inspect_(exec_id()) :: {:ok, %State{}} | {:error, String.t()}
  def inspect_(exec_id) do
    call(exec_id, :inspect)
  end

  defp call(exec_id, command) do
    case Registry.lookup(ExecInstances, exec_id) do
      [{pid, _container_id}] ->
        case Process.alive?(pid) do
          true -> GenServer.call(pid, command)
          false -> {:error, "could not find a execution instance matching '#{exec_id}'"}
        end

      [] ->
        {:error, "could not find a execution instance matching '#{exec_id}'"}
    end
  end

  ### ===================================================================
  ### gen_server callbacks
  ### ===================================================================
  @impl true
  def init([exec_id, config]) do
    {:ok, _} = Registry.register(ExecInstances, exec_id, config)
    {:ok, %State{exec_id: exec_id, config: config, subscribers: []}}
  end

  @impl true
  def handle_call({:stop, _}, _from, %State{port: nil} = state) do
    reply = {:ok, "execution instance not running, removing it anyway"}
    {:stop, :normal, reply, state}
  end

  def handle_call({:stop, %{stop_container: true}}, _from, state) do
    Logger.debug("#{state.exec_id}: stopping container")
    reply = Container.stop_container(state.container.id)
    await_exit_and_shutdown(reply, state)
  end

  def handle_call({:stop, %{stop_container: false} = opts}, _from, state) do
    Logger.debug("#{state.exec_id}: stopping executable")
    result = stop_executable(state, opts)
    await_exit_and_shutdown(result, state)
  end

  def handle_call({:attach, pid}, _from, %State{subscribers: subscribers} = state) do
    {:reply, :ok, %State{state | subscribers: Enum.uniq([pid | subscribers])}}
  end

  def handle_call({:start, _opts}, _from, %State{port: port} = state)
      when is_port(port) do
    reply = {:error, "executable already started"}
    {:reply, reply, state}
  end

  def handle_call({:start, %{start_container: start_container}}, _from, %State{port: nil} = state) do
    case start_(state.config, start_container) do
      {:error, _reason} = msg ->
        {:reply, msg, state}

      {:ok, port, container} when is_port(port) ->
        {:reply, :ok, %State{state | container: container, port: port}}
    end
  end

  def handle_call(:inspect, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_info({port, {:data, jail_output}}, %State{:port => port} = state) do
    Logger.debug("#{inspect(port)} Msg from executing port: #{inspect(jail_output)}")
    relay_msg({:jail_output, jail_output}, state)
    {:noreply, state}
  end

  def handle_info(
        {port, {:exit_status, exit_code}},
        %State{port: port} = state
      ) do
    shutdown_process(exit_code, state)
    {:stop, :normal, %State{state | :port => nil}}
  end

  def handle_info({_pid, {:input_data, jail_input}}, %State{:port => port} = state) do
    Port.command(port, jail_input)
    {:noreply, state}
  end

  def handle_info(unknown_msg, state) do
    Logger.warn("Unknown message: #{inspect(unknown_msg)}")
    {:noreply, state}
  end

  @spec stop_executable(%State{}, stop_options()) :: {:ok, String.t()} | {:error, String.t()}
  defp stop_executable(state, opts) do
    port_pid = Utils.get_os_pid_of_port(state.port)

    cmd_args =
      case opts do
        %{force_stop: true} -> ["-9", port_pid]
        %{force_stop: false} -> [port_pid]
      end

    case OS.cmd(["/bin/kill" | cmd_args]) do
      {_, 0} ->
        {:ok, "succesfully sent termination signal to executable"}

      {output, non_zero} ->
        Logger.warn(
          "Could not kill process, kill exited with code #{non_zero} and output: #{output}"
        )

        {:error, "error closing process: #{output}"}
    end
  end

  defp await_exit_and_shutdown({:error, _msg} = reply, state) do
    {:reply, reply, state}
  end

  defp await_exit_and_shutdown({:ok, _msg} = reply, %State{port: port} = state) do
    receive do
      {^port, {:exit_status, exit_code}} ->
        shutdown_process(exit_code, state)
        {:stop, :normal, reply, %State{state | port: nil}}
    after
      5_000 ->
        {:reply, {:error, "timed out while waiting for jail to exit"}, state}
    end
  end

  defp shutdown_process(exit_code, %State{config: config, container: container} = state) do
    case Utils.is_container_running?(config.container_id) do
      false ->
        msg = "#{state.exec_id} stopped with exit code #{exit_code}: {:shutdown, :jail_stopped}"
        Logger.debug(msg)
        jail_cleanup(container)
        relay_msg({:shutdown, {:jail_stopped, exit_code}}, state)

      true ->
        msg =
          "#{state.exec_id} stopped with exit code #{exit_code}: {:shutdown, :jailed_process_exited}"

        Logger.debug(msg)

        case Utils.is_zombie_jail?(container.id) do
          true ->
            Container.stop(container.id)

          false ->
            :ok
        end

        relay_msg({:shutdown, {:jailed_process_exited, exit_code}}, state)
    end
  end

  defp start_(config, start_container) do
    case MetaData.get_container(config.container_id) do
      %Schemas.Container{} = cont ->
        cont = merge_configurations(cont, config)

        case {Utils.is_container_running?(cont.id), start_container} do
          {true, _} ->
            port = jexec_container(cont, config.tty)
            {:ok, port, cont}

          {false, true} ->
            port = jail_start_container(cont, config.tty)
            {:ok, port, cont}

          {false, false} ->
            {:error, "cannot start container when 'start_container' is false."}
        end

      :not_found ->
        {:error, "container not found"}
    end
  end

  defp merge_configurations(
         %Schemas.Container{
           command: default_cmd,
           user: default_user,
           env: default_env
         } = cont,
         %Schemas.ExecConfig{
           cmd: exec_cmd,
           user: exec_user,
           env: exec_env
         }
       ) do
    env = Utils.merge_environment_variable_lists(default_env, exec_env)

    cmd =
      case exec_cmd do
        [] -> default_cmd
        _ -> exec_cmd
      end

    user =
      case exec_user do
        "" -> default_user
        _ -> exec_user
      end

    %Schemas.Container{cont | user: user, command: cmd, env: env}
  end

  defp jail_cleanup(%Schemas.Container{id: container_id, layer_id: layer_id}) do
    if Network.connected_to_vnet_networks?(container_id) do
      destoy_jail_epairs = fn network ->
        config = MetaData.get_endpoint(container_id, network.id)
        FreeBSD.destroy_bridged_epair(config.epair, network.bridge_if)
        config = %EndPoint{config | epair: nil}
        MetaData.add_endpoint_config(container_id, network.id, config)
      end

      MetaData.connected_networks(container_id) |> Enum.map(destoy_jail_epairs)
    end

    # remove any devfs mounts of the jail. If it was closed with 'jail -r <jailname>' devfs should be removed automatically.
    # If the jail stops because there jailed process stops (i.e. 'jail -c <etc> /bin/sleep 10') then devfs is NOT removed.
    # A race condition can also occur such that "jail -r" does not unmount before this call to mount.
    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    {output, _exitcode} = OS.cmd(["mount", "-t", "devfs"])
    output |> String.split("\n") |> Enum.map(&umount_container_devfs(&1, mountpoint))
  end

  defp jexec_container(
         %Schemas.Container{
           id: container_id,
           command: cmd,
           user: user,
           env: env
         },
         use_tty
       ) do
    # jexec [-l] [-u username | -U username] jail [command ...]
    args = ~w"-l -u #{user} #{container_id} /usr/bin/env -i" ++ env ++ cmd

    port = OS.cmd_async(['/usr/sbin/jexec' | args], use_tty)
    port
  end

  defp jail_start_container(
         %Schemas.Container{
           id: id,
           layer_id: layer_id,
           command: command,
           user: user,
           jail_param: jail_param,
           env: env
         } = cont,
         use_tty
       ) do
    Logger.info("Starting container #{inspect(cont.id)}")

    network_config = setup_connectivity_configuration(id)

    %Layer{mountpoint: path} = Kleened.Core.MetaData.get_layer(layer_id)

    args =
      ~w"-c path=#{path} name=#{id}" ++
        network_config ++
        jail_param ++
        ~w"exec.jail_user=#{user} command=/usr/bin/env -i" ++ env ++ command

    port = OS.cmd_async(['/usr/sbin/jail' | args], use_tty)
    port
  end

  defp setup_connectivity_configuration(container_id) do
    networks = MetaData.connected_networks(container_id)

    case network_type_used(networks) do
      :no_networks ->
        []

      :host ->
        ["ip4=inherit"]

      :loopback ->
        network_ids = Enum.map(networks, fn %Schemas.Network{id: id} -> id end)
        ips = Enum.map(network_ids, &extract_ip(container_id, &1))

        case Enum.join(ips, ",") do
          "" -> []
          ips_as_string -> ["ip4.addr=#{ips_as_string}"]
        end

      :vnet ->
        create_vnet_network_config(networks, container_id, [])
    end
  end

  defp create_vnet_network_config(
         [%Schemas.Network{id: id, bridge_if: bridge, subnet: subnet} | rest],
         container_id,
         network_configs
       ) do
    subnet = CIDR.parse(subnet)
    gateway = subnet.first |> :inet.ntoa() |> :binary.list_to_bin()

    %EndPoint{ip_address: ip} = endpoint = MetaData.get_endpoint(container_id, id)

    epair = FreeBSD.create_epair()
    MetaData.add_endpoint_config(container_id, id, %EndPoint{endpoint | epair: epair})
    # "exec.start=\"ifconfig #{epair}b name jail0\" " <>
    # "exec.poststop=\"ifconfig #{bridge} deletem #{epair}a\" " <>
    # "exec.poststop=\"ifconfig #{epair}a destroy\""
    network_configs = [
      "vnet",
      "vnet.interface=#{epair}b",
      "exec.prestart=ifconfig #{bridge} addm #{epair}a",
      "exec.prestart=ifconfig #{epair}a up",
      "exec.start=ifconfig #{epair}b #{ip}/#{subnet.mask}",
      "exec.start=route add -inet default #{gateway}"
      | network_configs
    ]

    create_vnet_network_config(rest, container_id, network_configs)
  end

  defp create_vnet_network_config([], _, network_configs) do
    network_configs
  end

  def extract_ip(container_id, network_id) do
    config = MetaData.get_endpoint(container_id, network_id)
    config.ip_address
  end

  defp network_type_used(networks) do
    case networks do
      [] -> :no_networks
      [%Schemas.Network{driver: "host"}] -> :host
      [%Schemas.Network{driver: "loopback"} | _] -> :loopback
      [%Schemas.Network{driver: "vnet"} | _] -> :vnet
      invalid_response -> Logger.error("Invalid response: #{inspect(invalid_response)}")
    end
  end

  defp relay_msg(msg, state) do
    wrapped_msg = {:container, state.exec_id, msg}

    Enum.map(state.subscribers, fn x ->
      Logger.debug("relaying to #{inspect(x)}: #{inspect(msg)}")
      Process.send(x, wrapped_msg, [])
    end)
  end

  defp umount_container_devfs(line, mountpoint) do
    case String.contains?(line, mountpoint) do
      true ->
        devfs_path = Path.join(mountpoint, "dev")
        OS.cmd(["/sbin/umount", devfs_path])

      _ ->
        :ok
    end
  end
end