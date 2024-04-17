defmodule Kleened.Core.Exec do
  alias Kleened.Core.{Container, Network, MetaData, OS, FreeBSD, ZFS, Utils, ExecInstances, Mount}
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
        {:error, "could not find execution instance matching '#{exec_id}'"}
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
          false -> {:error, "could not find execution instance matching '#{exec_id}'"}
        end

      [] ->
        {:error, "could not find execution instance matching '#{exec_id}'"}
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
  def handle_call({:stop, %{stop_container: true}}, _from, state) do
    Logger.debug("#{state.exec_id}: stopping container")

    reply =
      case state.container do
        %Schemas.Container{} ->
          Container.stop(state.container.id)

          case await_process_exit(state) do
            {:exited, exit_code, _state} ->
              relay_msg({:shutdown, {:jail_stopped, exit_code}}, state)
              {:ok, state.container.id}

            {:error, reason} ->
              {:error, reason}
          end

        :not_started ->
          {:error, "execution instance have not been started"}
      end

    {:stop, :normal, reply, state}
  end

  def handle_call({:stop, %{stop_container: false} = opts}, _from, state) do
    Logger.debug("#{state.exec_id}: stopping executable")

    reply =
      case stop_executable(state, opts) do
        :ok ->
          case await_process_exit(state) do
            {:exited, exit_code, state} ->
              shutdown_process(exit_code, state)
              {:ok, state.container.id}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

    {:stop, :normal, reply, state}
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
    case start_(state.config, start_container, state) do
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
    case Utils.get_os_pid_of_port(state.port) do
      nil ->
        {:error, "the process port has already exited"}

      port_pid ->
        cmd_args =
          case opts do
            %{force_stop: true} -> ["-9", port_pid]
            %{force_stop: false} -> [port_pid]
          end

        case OS.cmd(["/bin/kill" | cmd_args]) do
          {_, 0} ->
            :ok

          {output, non_zero} ->
            Logger.warning(
              "Could not kill process, kill exited with code #{non_zero} and output: #{output}"
            )

            {:error, "error closing process: #{output}"}
        end
    end
  end

  defp await_process_exit(%State{port: port} = state) do
    receive do
      {^port, {:exit_status, exit_code}} ->
        {:exited, exit_code, %State{state | port: nil}}
    after
      5_000 ->
        {:error, "timed out while waiting for jail to stop"}
    end
  end

  defp shutdown_process(exit_code, %State{config: config, container: container} = state) do
    case Utils.is_container_running?(config.container_id) do
      false ->
        msg = "#{state.exec_id} and container #{container.id} exited with code #{exit_code}."

        Logger.debug(msg)
        Container.cleanup_container(container)
        relay_msg({:shutdown, {:jail_stopped, exit_code}}, state)

      true ->
        msg = "exec #{state.exec_id} exited with code #{exit_code}"

        Logger.debug(msg)
        relay_msg({:shutdown, {:jailed_process_exited, exit_code}}, state)
    end
  end

  defp start_(config, start_container, state) do
    case MetaData.get_container(config.container_id) do
      %Schemas.Container{} = cont ->
        cont = merge_configurations(cont, config)

        case {Utils.is_container_running?(cont.id), start_container} do
          {true, _} ->
            port = jexec_start_container(cont, config.tty)
            {:ok, port, cont}

          {false, true} ->
            port = jail_start_container(cont, config.tty, state)
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

  defp jexec_start_container(
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
         use_tty,
         state
       ) do
    Logger.info("Starting container #{id}")
    setup_mounts(container, state)
    setup_networking(container, state)
    network_config = create_networking_jail_params(container)
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

  defp setup_mounts(container, state) do
    MetaData.get_mounts_from_container(container.id)
    |> Enum.map(fn
      mountpoint ->
        case(Mount.mount(container, mountpoint)) do
          :ok ->
            :ok

          {:error, reason} ->
            msg = "could not mount #{inspect(mountpoint)}: #{reason}"
            Logger.warning(msg)
            relay_msg(msg, state)
        end
    end)
  end

  def setup_networking(container, state) do
    endpoints = MetaData.get_endpoints_from_container(container.id)

    case container.network_driver do
      "vnet" -> Enum.map(endpoints, &setup_vnet_network(&1, state))
      "ipnet" -> Enum.map(endpoints, &setup_ipnet_network(&1, state))
      _ -> []
    end
  end

  defp setup_vnet_network(endpoint, state) do
    case FreeBSD.create_epair() do
      {:ok, epair} ->
        endpoint = %Schemas.EndPoint{endpoint | epair: epair}
        MetaData.add_endpoint(endpoint.container_id, endpoint.network_id, endpoint)

      {:error, reason} ->
        msg = "could not create new epair, ifconfig failed with: #{reason}"
        Logger.warning(msg)
        relay_msg(msg, state)
    end
  end

  defp setup_ipnet_network(endpoint, state) do
    Enum.map(
      [{endpoint.ip_address, "inet"}, {endpoint.ip_address6, "inet6"}],
      fn
        {"", _} ->
          :ok

        {ip, protocol} ->
          network = MetaData.get_network(endpoint.network_id)

          case FreeBSD.ifconfig_alias(ip, network.interface, protocol) do
            :ok ->
              :ok

            {:error, reason} ->
              msg = "could not add ip to #{network.interface}: #{reason}"
              Logger.warning(msg)
              relay_msg(msg, state)
          end
      end
    )
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

  defp create_networking_jail_params(%Schemas.Container{network_driver: "disabled"}) do
    ["ip4=disable", "ip6=disable"]
  end

  defp create_networking_jail_params(%Schemas.Container{network_driver: "host"}) do
    ["ip4=inherit", "ip6=inherit"]
  end

  defp create_networking_jail_params(%Schemas.Container{network_driver: "ipnet"} = container) do
    networks = MetaData.connected_networks(container.id)
    Enum.flat_map(networks, &create_ipnet_network_config(&1, container.id))
  end

  defp create_networking_jail_params(%Schemas.Container{network_driver: "vnet"} = container) do
    networks = MetaData.connected_networks(container.id)
    config = ["vnet" | Enum.flat_map(networks, &create_vnet_network_config(&1, container.id))]
    Kleened.Core.Network.configure_pf()
    config
  end

  defp create_ipnet_network_config(
         %Schemas.Network{id: network_id, interface: interface},
         container_id
       ) do
    %Schemas.EndPoint{ip_address: ip_address, ip_address6: ip_address6} =
      MetaData.get_endpoint(container_id, network_id)

    ip_jailparam =
      case ip_address do
        "" ->
          []

        ip ->
          [
            "exec.prestart=ifconfig #{interface} inet #{ip}/32 alias",
            "ip4.addr=#{ip}"
          ]
      end

    ip6_jailparam =
      case ip_address6 do
        "" ->
          []

        ip6 ->
          [
            "exec.prestart=ifconfig #{interface} inet6 #{ip6}/128 alias",
            "ip6.addr=#{ip6}"
          ]
      end

    # This was previously done by having one ip4.addr param
    # containing all ips in a comma-seperated list.
    ip_jailparam ++ ip6_jailparam
  end

  defp create_vnet_network_config(
         %Schemas.Network{
           id: network_id,
           interface: bridge,
           subnet: subnet,
           subnet6: subnet6,
           gateway: gateway,
           gateway6: gateway6
         },
         container_id
       ) do
    %Schemas.EndPoint{epair: epair, ip_address: ip, ip_address6: ip6} =
      MetaData.get_endpoint(container_id, network_id)

    base_config = [
      "vnet.interface=#{epair}b",
      "exec.prestart=ifconfig #{bridge} addm #{epair}a",
      "exec.prestart=ifconfig #{epair}a up"
    ]

    extended_config =
      create_exec_start_params([],
        subnet: {epair, subnet, ip},
        gateway: {gateway, subnet},
        subnet6: {epair, subnet6, ip6},
        gateway6: {gateway6, subnet6}
      )

    base_config ++ extended_config
  end

  defp create_exec_start_params(config, [{_, ""} | rest]) do
    create_exec_start_params(config, rest)
  end

  defp create_exec_start_params(config, [{:subnet, {_epair, subnet, ip}} | rest])
       when subnet == "" or ip == "" do
    create_exec_start_params(config, rest)
  end

  defp create_exec_start_params(config, [{:subnet, {epair, subnet, ip}} | rest]) do
    %CIDR{} = subnet = CIDR.parse(subnet)

    create_exec_start_params(
      ["exec.start=ifconfig #{epair}b inet #{ip}/#{subnet.mask}" | config],
      rest
    )
  end

  defp create_exec_start_params(config, [{:subnet6, {_epair, subnet6, ip6}} | rest])
       when subnet6 == "" or ip6 == "" do
    create_exec_start_params(config, rest)
  end

  defp create_exec_start_params(config, [{:subnet6, {epair, subnet6, ip6}} | rest]) do
    %CIDR{} = subnet6 = CIDR.parse(subnet6)

    create_exec_start_params(
      ["exec.start=ifconfig #{epair}b inet6 #{ip6}/#{subnet6.mask}" | config],
      rest
    )
  end

  defp create_exec_start_params(config, [{:gateway, {"", _}} | rest]) do
    create_exec_start_params(config, rest)
  end

  defp create_exec_start_params(config, [{:gateway, {_gateway, ""}} | rest]) do
    create_exec_start_params(config, rest)
  end

  defp create_exec_start_params(config, [{:gateway, {"<auto>", subnet}} | rest]) do
    auto_gateway = Network.first_ip_address(subnet, "inet")
    create_exec_start_params(config, [{:gateway, {auto_gateway, subnet}} | rest])
  end

  defp create_exec_start_params(config, [{:gateway, {gateway, _subnet}} | rest]) do
    create_exec_start_params(["exec.start=route add -inet default #{gateway}" | config], rest)
  end

  defp create_exec_start_params(config, [{:gateway6, {"", _}} | rest]) do
    create_exec_start_params(config, rest)
  end

  defp create_exec_start_params(config, [{:gateway6, {_gateway6, ""}} | rest]) do
    create_exec_start_params(config, rest)
  end

  defp create_exec_start_params(config, [{:gateway6, {"<auto>", subnet6}} | rest]) do
    auto_gateway6 = Network.first_ip_address(subnet6, "inet6")
    create_exec_start_params(config, [{:gateway6, {auto_gateway6, subnet6}} | rest])
  end

  defp create_exec_start_params(config, [{:gateway6, {gateway6, _subnet6}} | rest]) do
    create_exec_start_params(["exec.start=route add -inet6 default #{gateway6}" | config], rest)
  end

  defp create_exec_start_params(config, []) do
    # Reversing the order of jail parameters otherwise we would add the
    # gateway before the subnet and then fail to start the jail properly
    Enum.reverse(config)
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
