defmodule Kleened.Core.Exec do
  alias Kleened.Core.{Container, MetaData, OS, FreeBSD, ZFS, Utils, ExecInstances}
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
        {:error, "container not found"}
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
    reply = Container.stop(state.container.id)
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
    relay_msg({:jail_output, jail_output}, state)
    {:noreply, state}
  end

  def handle_info(
        {port, {:exit_status, exit_code}},
        %State{port: port} = state
      ) do
    Logger.notice("execution of #{state.exec_id} within #{state.container.id} stopped")
    shutdown_process(exit_code, state)
    {:stop, :normal, %State{state | :port => nil}}
  end

  def handle_info({_pid, {:input_data, jail_input}}, %State{:port => port} = state) do
    Port.command(port, jail_input)
    {:noreply, state}
  end

  def handle_info(unknown_msg, state) do
    Logger.warning("Unknown message: #{inspect(unknown_msg)}")
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
        Logger.warning(
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
           cmd: default_cmd,
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

    %Schemas.Container{cont | user: user, cmd: cmd, env: env}
  end

  defp jail_cleanup(%Schemas.Container{id: container_id, network_driver: driver, dataset: dataset}) do
    if driver == "vnet" do
      destoy_jail_epairs = fn network ->
        config = MetaData.get_endpoint(container_id, network.id)
        FreeBSD.destroy_bridged_epair(config.epair, network.interface)
        config = %Schemas.EndPoint{config | epair: nil}
        MetaData.add_endpoint(container_id, network.id, config)
      end

      MetaData.connected_networks(container_id) |> Enum.map(destoy_jail_epairs)
    end

    # remove any devfs mounts of the jail. If it was closed with 'jail -r <jailname>' devfs should be removed automatically.
    # If the jail stops because there jailed process stops (i.e. 'jail -c <etc> /bin/sleep 10') then devfs is NOT removed.
    # A race condition can also occur such that "jail -r" does not unmount before this call to mount.
    mountpoint = ZFS.mountpoint(dataset)
    FreeBSD.clear_devfs(mountpoint)
  end

  defp jexec_container(
         %Schemas.Container{
           id: container_id,
           cmd: cmd,
           user: user,
           env: env
         },
         use_tty
       ) do
    # jexec [-l] [-u username | -U username] jail [command ...]
    args = ~w"-l -U #{user} #{container_id} /usr/bin/env" ++ env ++ cmd

    port = OS.cmd_async(['/usr/sbin/jexec' | args], use_tty)
    port
  end

  defp jail_start_container(
         %Schemas.Container{
           id: id,
           dataset: dataset,
           cmd: command,
           user: user,
           jail_param: jail_param,
           env: env
         } = container,
         use_tty
       ) do
    Logger.info("Starting container #{id}")
    network_config = setup_connectivity_configuration(container)
    path = ZFS.mountpoint(dataset)

    # Since booleans can have two different forms:
    # - w/o 'no' prefix ['nopersist', 'exec.noclean']
    # - <param>=true/false ['persist=false', 'exec.clean=false']
    # 'paramtype' can both be a list of two or one variant(s)
    default_exec_stop = "exec.stop=\"/bin/sh /etc/rc.shutdown\""

    jail_param =
      jail_param
      |> update_jailparam_if_not_exist(["host.hostname"], "host.hostname=#{id}")
      |> update_jailparam_if_not_exist(["exec.jail_user"], "exec.jail_user=#{user}")
      |> update_jailparam_if_not_exist(["exec.clean", "exec.noclean"], "exec.clean=true")
      |> update_jailparam_if_not_exist(["exec.stop", "exec.nostop"], default_exec_stop)
      |> update_jailparam_if_not_exist(["mount.devfs", "mount.nodevfs"], "mount.devfs=true")

    args =
      ~w"-c path=#{path} name=#{id}" ++
        network_config ++
        jail_param ++
        ["command=/usr/bin/env"] ++ env ++ command

    port = OS.cmd_async(['/usr/sbin/jail' | args], use_tty)
    port
  end

  defp update_jailparam_if_not_exist(jail_params, paramtype, default_value) do
    case if_paramtype_exist?(jail_params, paramtype) do
      true ->
        jail_params

      false ->
        [default_value | jail_params]
    end
  end

  defp if_paramtype_exist?([jail_param | rest], paramtype) do
    case paramtype
         |> Enum.map(&(String.slice(jail_param, 0, String.length(&1)) == &1))
         |> Enum.any?() do
      false -> if_paramtype_exist?(rest, paramtype)
      true -> true
    end
  end

  defp if_paramtype_exist?([], _paramtype) do
    false
  end

  defp setup_connectivity_configuration(%Schemas.Container{network_driver: "disabled"}) do
    ["ip4=disable", "ip6=disable"]
  end

  defp setup_connectivity_configuration(%Schemas.Container{network_driver: "host"}) do
    ["ip4=inherit", "ip6=inherit"]
  end

  defp setup_connectivity_configuration(container) do
    case MetaData.connected_networks(container.id) do
      [] -> []
      networks -> setup_connectivity_configuration(container, networks)
    end
  end

  defp setup_connectivity_configuration(
         %Schemas.Container{network_driver: "ipnet"} = container,
         networks
       ) do
    Enum.flat_map(networks, &create_alias_network_config(&1, container.id))
  end

  defp setup_connectivity_configuration(
         %Schemas.Container{network_driver: "vnet"} = container,
         networks
       ) do
    config = Enum.flat_map(networks, &create_vnet_network_config(&1, container.id))
    Kleened.Core.Network.configure_pf()
    config
  end

  defp create_alias_network_config(network, container_id) do
    endpoint = MetaData.get_endpoint(container_id, network.id)

    ip_jailparam =
      case endpoint.ip_address do
        "" -> []
        ip -> ["ip4.addr=#{ip}"]
      end

    ip6_jailparam =
      case endpoint.ip_address6 do
        "" -> []
        ip6 -> ["ip6.addr=#{ip6}"]
      end

    # NOTE This was previously done by having one ip4.addr param
    # containing all ips in a comma-seperated list.
    ip_jailparam ++ ip6_jailparam
  end

  defp create_vnet_network_config(
         %Schemas.Network{
           id: id,
           interface: bridge,
           subnet: subnet,
           subnet6: subnet6,
           gateway: gateway,
           gateway6: gateway6
         },
         container_id
       ) do
    %Schemas.EndPoint{ip_address: ip, ip_address6: ip6} =
      endpoint = MetaData.get_endpoint(container_id, id)

    epair = FreeBSD.create_epair()
    MetaData.add_endpoint(container_id, id, %Schemas.EndPoint{endpoint | epair: epair})
    # "exec.start=\"ifconfig #{epair}b name jail0\" " <>
    # "exec.poststop=\"ifconfig #{bridge} deletem #{epair}a\" " <>
    # "exec.poststop=\"ifconfig #{epair}a destroy\""
    base_config = [
      "vnet",
      "vnet.interface=#{epair}b",
      "exec.prestart=ifconfig #{bridge} addm #{epair}a",
      "exec.prestart=ifconfig #{epair}a up"
    ]

    extended_config =
      create_extended_config([],
        subnet: {epair, subnet, ip},
        gateway: gateway,
        subnet6: {epair, subnet6, ip6},
        gateway6: gateway6
      )

    base_config ++ extended_config
  end

  defp create_extended_config(config, []) do
    # We need to reverse the order of jail parameters.
    # Otherwise we would add the gateway before the subnet (and then fail)
    # when starting the jail
    Enum.reverse(config)
  end

  defp create_extended_config(config, [{_, ""} | rest]) do
    # extended_config = [
    #  "exec.start=ifconfig #{epair}b #{ip}/#{subnet.mask}",
    #  "exec.start=route add -inet default #{gateway}"
    # ]
    create_extended_config(config, rest)
  end

  defp create_extended_config(config, [{:subnet, {_epair, subnet, ip}} | rest])
       when subnet == "" or ip == "" do
    create_extended_config(config, rest)
  end

  defp create_extended_config(config, [{:subnet, {epair, subnet, ip}} | rest]) do
    %CIDR{} = subnet = CIDR.parse(subnet)

    create_extended_config(
      ["exec.start=ifconfig #{epair}b inet #{ip}/#{subnet.mask}" | config],
      rest
    )
  end

  defp create_extended_config(config, [{:subnet6, {_epair, subnet6, ip6}} | rest])
       when subnet6 == "" or ip6 == "" do
    create_extended_config(config, rest)
  end

  defp create_extended_config(config, [{:subnet6, {epair, subnet6, ip6}} | rest]) do
    %CIDR{} = subnet6 = CIDR.parse(subnet6)

    create_extended_config(
      ["exec.start=ifconfig #{epair}b inet6 #{ip6}/#{subnet6.mask}" | config],
      rest
    )
  end

  defp create_extended_config(config, [{:gateway, gateway} | rest]) do
    create_extended_config(["exec.start=route add -inet default #{gateway}" | config], rest)
  end

  defp create_extended_config(config, [{:gateway6, gateway6} | rest]) do
    create_extended_config(["exec.start=route add -inet6 default #{gateway6}" | config], rest)
  end

  def extract_ip(container_id, network_id, "inet") do
    config = MetaData.get_endpoint(container_id, network_id)
    config.ip_address
  end

  defp relay_msg(msg, state) do
    wrapped_msg = {:container, state.exec_id, msg}

    Enum.map(state.subscribers, fn x ->
      Logger.debug("relaying from #{inspect(state.port)} to #{inspect(x)}: #{inspect(msg)}")
      Process.send(x, wrapped_msg, [])
    end)
  end
end
