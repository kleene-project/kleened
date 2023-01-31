defmodule Jocker.Engine.Network do
  use GenServer
  alias Jocker.Engine.{Config, Container, Utils, MetaData, OS, FreeBSD}
  alias Jocker.API.Schemas
  require Logger

  alias __MODULE__, as: Network

  defmodule EndPointConfig do
    @derive Jason.Encoder
    defstruct id: nil,
              epair: nil,
              ip_address: nil
  end

  defmodule State do
    defstruct pf_config_path: nil,
              gateway_interface: nil
  end

  @type t() :: %Schemas.Network{}
  @type network_id() :: String.t()
  @type network_config :: %Schemas.NetworkConfig{}
  @type endpoint_config() :: %EndPointConfig{}

  @default_pf_configuration """
  # This is the pf(4) configuration file template that is used by Jocker.
  # Feel free to add additional rules as long as the tags (and their ordering) below are preserved.
  # Modify with care: It can potentially affect Jocker in unpredictable ways.
  # The resulting configuration file that is loaded into pf is defined at the 'pf_config_path'
  # entry in the jocker engine configuration file (jocker_config.yaml).

  ### JOCKER MACROS START ###
  <%= jocker_macros %>
  ### JOCKER MACROS END #####

  ### JOCKER TRANSLATION RULES START ###
  <%= jocker_translation %>
  ### JOCKER TRANSLATION RULES END #####

  ### JOCKER FILTERING RULES START #####
  # block everything
  #block log all

  # skip loopback interface(s)
  set skip on lo0

  <%= jocker_filtering %>
  ### JOCKER FILTERING RULES END #######
  """

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  ### Docker Engine style API's
  @spec create(network_config()) ::
          {:ok, Network.t()} | {:error, String.t()}
  def create(options) do
    GenServer.call(__MODULE__, {:create, options})
  end

  @spec connect(String.t(), String.t()) :: {:ok, endpoint_config()} | {:error, String.t()}
  def connect(container_idname, network_idname) do
    GenServer.call(__MODULE__, {:connect, container_idname, network_idname}, 10_000)
  end

  @spec connect(String.t(), String.t()) :: :ok | {:error, String.t()}
  def disconnect(container_idname, network_idname) do
    GenServer.call(__MODULE__, {:disconnect, container_idname, network_idname})
  end

  def disconnect_all(container_id) do
    GenServer.call(__MODULE__, {:disconnect_all, container_id})
  end

  @spec list() :: [Network.t()]
  def list() do
    GenServer.call(__MODULE__, :list)
  end

  @spec remove(String.t()) :: {:ok, Network.network_id()} | {:error, String.t()}
  def remove(idname) do
    GenServer.call(__MODULE__, {:remove, idname})
  end

  def inspect_(network_idname) do
    GenServer.call(__MODULE__, {:inspect, network_idname})
  end

  def inspect_endpoint(container_id, network_id) do
    GenServer.call(__MODULE__, {:inspect_endpoint, container_id, network_id})
  end

  ### Callback functions
  @impl true
  def init([]) do
    pf_conf_path = Config.get("pf_config_path")

    gateway =
      case Config.get("default_gateway_if") do
        nil ->
          detect_gateway_if()

        gw ->
          gw
      end

    FreeBSD.enable_ip_forwarding()

    if not Utils.touch(pf_conf_path) do
      Logger.error("Unable to access Jockers PF configuration file located at #{pf_conf_path}")
    end

    create_loopback_interfaces()
    state = %State{:pf_config_path => pf_conf_path, :gateway_interface => gateway}

    # Adding the special 'host' network (meaning use ip4=inherit when jails are connected to it)
    MetaData.add_network(%Schemas.Network{id: "host", name: "host", driver: "host", subnet: "n/a"})

    enable_pf()
    configure_pf(pf_conf_path, gateway)
    {:ok, state}
  end

  @impl true
  def handle_call({:create, options}, _from, state) do
    reply = create_(options, state)
    {:reply, reply, state}
  end

  def handle_call({:connect, container_idname, network_idname}, _from, state) do
    container = MetaData.get_container(container_idname)
    network = MetaData.get_network(network_idname)
    reply = connect_(container, network)
    {:reply, reply, state}
  end

  def handle_call({:disconnect, container_idname, network_idname}, _from, state) do
    reply = disconnect_(container_idname, network_idname)
    {:reply, reply, state}
  end

  def handle_call({:disconnect_all, container_id}, _from, state) do
    network_ids =
      MetaData.connected_networks(container_id) |> Enum.map(fn network -> network.id end)

    Enum.map(network_ids, &disconnect_(container_id, &1))
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    networks = MetaData.list_networks(:include_host)
    {:reply, networks, state}
  end

  def handle_call({:remove, idname}, _from, state) do
    case MetaData.get_network(idname) do
      %Schemas.Network{id: id, driver: "loopback", loopback_if: if_name} ->
        container_ids = MetaData.connected_containers(id)
        Enum.map(container_ids, &disconnect_(&1, id))
        Utils.destroy_interface(if_name)
        MetaData.remove_network(id)
        configure_pf(state.pf_config_path, state.gateway_interface)
        {:reply, {:ok, id}, state}

      %Schemas.Network{id: id, driver: "vnet", bridge_if: if_name} ->
        container_ids = MetaData.connected_containers(id)
        Enum.map(container_ids, &disconnect_(&1, id))

        # Just in case there are more members added:
        remove_bridge_members(if_name)

        Utils.destroy_interface(if_name)
        MetaData.remove_network(id)
        configure_pf(state.pf_config_path, state.gateway_interface)
        {:reply, {:ok, id}, state}

      :not_found ->
        {:reply, {:error, "network not found."}, state}
    end
  end

  def handle_call({:inspect, idname}, _from, state) do
    network = MetaData.get_network(idname)
    {:reply, network, state}
  end

  def handle_call({:inspect_endpoint, container_id, network_id}, _from, state) do
    endpoint_config = MetaData.get_endpoint_config(container_id, network_id)
    {:reply, endpoint_config, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  ##########################
  ### Internal functions ###
  ##########################
  def create_(%Schemas.NetworkConfig{name: "host"}, _state) do
    {:error, "network name 'host' is reserved and cannot be used"}
  end

  def create_(
        %Schemas.NetworkConfig{driver: driver, name: name, subnet: subnet, ifname: loopback_if},
        state
      ) do
    parsed_subnet = CIDR.parse(subnet)

    cond do
      MetaData.get_network(name) != :not_found ->
        {:error, "network name is already taken"}

      not is_map(parsed_subnet) or parsed_subnet.__struct__ != CIDR ->
        {:error, "invalid subnet"}

      driver == "loopback" ->
        create_loopback_network(name, loopback_if, subnet, state)

      driver == "vnet" ->
        create_vnet_network(name, subnet, state)

      true ->
        {:error, "Unknown driver #{inspect(driver)}"}
    end
  end

  defp connect_(_container, :not_found) do
    Logger.warn("Could not connect container to network: network not found")
    {:reply, {:error, "container not found"}}
  end

  defp connect_(:not_found, _network) do
    Logger.warn("Could not connect container to network: container not found")
    {:reply, {:error, "network not found"}}
  end

  defp connect_(container, network) do
    case MetaData.get_endpoint_config(container.id, network.id) do
      %EndPointConfig{} ->
        {:error, "container already connected to the network"}

      :not_found ->
        connect_with_driver(container, network)
    end
  end

  defp connect_with_driver(
         %Schemas.Container{id: container_id},
         %Schemas.Network{id: "host"} = network
       ) do
    cond do
      Container.is_running?(container_id) ->
        # A jail with 'ip4="new"' (or using a VNET) cannot be modified to use 'ip="inherit"'
        {:error, "cannot connect a running container to the hosts network"}

      true ->
        case MetaData.connected_networks(container_id) do
          # A jail with 'ip4=inherit' cannot use VNET's or impose restrictions on ip-addresses
          # using ip4.addr
          [] ->
            config = %EndPointConfig{}
            MetaData.add_endpoint_config(container_id, network.id, config)
            {:ok, config}

          _ ->
            {:error, "cannot connect to host network simultaneously with other networks"}
        end
    end
  end

  defp connect_with_driver(
         %Schemas.Container{id: container_id},
         %Schemas.Network{driver: "loopback"} = network
       ) do
    cond do
      connected_to_host_network?(container_id) ->
        {:error, "connected to host network"}

      connected_to_vnet_networks?(container_id) ->
        {:error,
         "already connected to a vnet network and containers can't be connected to both vnet and loopback networks"}

      true ->
        ip = new_ip(network)
        config = %EndPointConfig{ip_address: ip}
        MetaData.add_endpoint_config(container_id, network.id, config)

        case OS.cmd(~w"ifconfig #{network.loopback_if} alias #{ip}/32") do
          {_, 0} ->
            if Container.is_running?(container_id) do
              add_jail_ip(container_id, ip)
            end

            {:ok, config}

          {error_output, _nonzero_exitcode} ->
            {:error, "could not add ip #{ip} to container #{container_id}: #{error_output}"}
        end
    end
  end

  defp connect_with_driver(
         %Schemas.Container{} = container,
         %Schemas.Network{driver: "vnet"} = network
       ) do
    cond do
      connected_to_host_network?(container.id) ->
        {:error, "connected to host network"}

      Utils.is_container_running?(container.id) ->
        {:error, "cannot connect a running container to a vnet network"}

      connected_to_loopback_networks?(container.id) ->
        {:error,
         "already connected to a loopback network and containers can't be connected to both vnet and loopback networks"}

      true ->
        ip = new_ip(network)
        config = %EndPointConfig{ip_address: ip}
        MetaData.add_endpoint_config(container.id, network.id, config)
        {:ok, config}
    end
  end

  defp connect_with_driver(network, container) do
    Logger.warn(
      "Unknown error occured when connecting container '#{inspect(container)}' to network '#{
        inspect(network)
      }'"
    )

    {:reply, {:error, "unknown error"}}
  end

  def disconnect_(container_idname, network_idname) do
    cont = %Schemas.Container{id: container_id} = MetaData.get_container(container_idname)
    network = MetaData.get_network(network_idname)
    config = MetaData.get_endpoint_config(container_id, network.id)

    cond do
      cont == :not_found ->
        {:error, "container not found"}

      network == :not_found ->
        {:error, "network not found"}

      config == :not_found ->
        {:error, "endpoint configuration not found"}

      network.driver == "host" ->
        # The container needs to be restarted for the disconnect to take effect.
        MetaData.remove_endpoint_config(container_id, network.id)

      network.driver == "loopback" ->
        # Remove ip-addresses from the jail, network interface, and database
        ifconfig_remove_alias(config.ip_address, network.loopback_if)

        if Container.is_running?(container_id) do
          remove_jail_ips(container_id, config.ip_address)
        end

        MetaData.remove_endpoint_config(container_id, network.id)

      network.driver == "vnet" ->
        if config.epair != nil do
          FreeBSD.destroy_bridged_vnet_epair(config.epair, network.bridge_if, container_id)
        end

        MetaData.remove_endpoint_config(container_id, network.id)

      true ->
        Logger.error("this should not happen!")
        {:error, "unknown error occured"}
    end
  end

  defp remove_bridge_members(bridge) do
    remove_if_member = fn line ->
      case String.contains?(line, "member: ") do
        true ->
          [_, epair | _rest] = String.split(line)
          {_output, 0} = OS.cmd(~w"ifconfig #{bridge} deletem #{epair}")

        false ->
          :ok
      end
    end

    {output, 0} = OS.cmd(~w"ifconfig #{bridge}")
    lines = output |> String.trim() |> String.split("\n") |> Enum.map(&String.trim/1)
    Enum.map(lines, remove_if_member)
  end

  def configure_pf(pf_config_path, default_gw) do
    networks = MetaData.list_networks(:exclude_host)

    state = %{
      :macros => [
        "gw_if=\"#{default_gw}\" # This should be the interface of your default gateway"
      ],
      :translation => [],
      :filtering => []
    }

    FreeBSD.enable_ip_forwarding()
    pf_config = create_pf_config(networks, state)
    load_pf_config(pf_config_path, pf_config)
  end

  def create_pf_config(
        [%Schemas.Network{driver: "loopback", loopback_if: if_name, subnet: subnet} | rest],
        %{macros: macros, translation: translation} = state
      ) do
    new_macro = "jocker_loopback_#{if_name}_subnet=\"#{subnet}\""
    nat_subnet = "nat on $gw_if from $jocker_loopback_#{if_name}_subnet to any -> ($gw_if)"

    new_state = %{
      state
      | :macros => [new_macro | macros],
        :translation => [nat_subnet | translation]
    }

    create_pf_config(rest, new_state)
  end

  def create_pf_config(
        [%Schemas.Network{driver: "vnet", bridge_if: bridge_name, subnet: subnet} | rest],
        %{macros: macros, translation: translation} = state
      ) do
    new_macro1 = "jocker_bridge_#{bridge_name}_subnet=\"#{subnet}\""
    new_macro2 = "jocker_bridge_#{bridge_name}_if=\"#{bridge_name}\""

    nat_bridged_network =
      "nat on $gw_if inet from ($jocker_bridge_#{bridge_name}_if:network) to any -> ($gw_if)"

    new_state = %{
      state
      | :macros => [new_macro1, new_macro2 | macros],
        :translation => [nat_bridged_network | translation]
    }

    create_pf_config(rest, new_state)
  end

  def create_pf_config([], %{
        :macros => macros,
        :translation => translation,
        :filtering => filtering
      }) do
    EEx.eval_string(@default_pf_configuration,
      jocker_macros: Enum.join(macros, "\n"),
      jocker_translation: Enum.join(translation, "\n"),
      jocker_filtering: Enum.join(filtering, "\n")
    )
  end

  def enable_pf() do
    System.cmd("/sbin/pfctl", ["-e"], stderr_to_stdout: true)
  end

  def load_pf_config(pf_config_path, config) do
    case File.write(pf_config_path, config, [:write]) do
      :ok ->
        case System.cmd("/sbin/pfctl", ["-f", pf_config_path]) do
          {_, 0} ->
            :ok

          {"", 1} ->
            Logger.error("Failed to load PF configuration file. 'pfctl' returned with an error.")

          {error_output, 1} ->
            Logger.error(
              "Failed to load PF configuration file. 'pfctl' returned the following error: #{
                inspect(error_output)
              }"
            )
        end

      {:error, reason} ->
        Logger.error("Failed to write PF configuration file with reason: #{inspect(reason)} ")
    end
  end

  defp create_loopback_interfaces() do
    MetaData.list_networks(:exclude_host)
    |> Enum.map(fn
      %Schemas.Network{driver: "loopback", loopback_if: if_name} ->
        ifconfig_loopback_create(if_name)

      _ ->
        :ok
    end)
  end

  def create_loopback_network(name, if_name, subnet, state) do
    network = %Schemas.Network{
      id: Utils.uuid(),
      name: name,
      subnet: subnet,
      loopback_if: if_name,
      driver: "loopback"
    }

    case ifconfig_loopback_create(if_name) do
      {_, 0} ->
        MetaData.add_network(network)
        configure_pf(state.pf_config_path, state.gateway_interface)
        {:ok, network}

      {error_output, _exitcode} ->
        {:error, "ifconfig failed with output: #{error_output}"}
    end
  end

  def create_vnet_network(name, subnet, state) do
    network = %Schemas.Network{
      id: Utils.uuid(),
      name: name,
      subnet: subnet,
      driver: "vnet"
    }

    case OS.cmd(~w"ifconfig bridge create") do
      {bridge_name, 0} ->
        bridge_name = String.trim(bridge_name)
        %CIDR{:first => ip, :mask => mask} = CIDR.parse(subnet)
        # :inet.ntoa/1 produces erlang strings :S
        ip = :binary.list_to_bin(:inet.ntoa(ip))

        case OS.cmd(~w"ifconfig #{bridge_name} alias #{ip}/#{mask}") do
          {"", 0} ->
            network = %Schemas.Network{network | bridge_if: bridge_name}
            MetaData.add_network(network)
            configure_pf(state.pf_config_path, state.gateway_interface)
            {:ok, network}

          {error_msg, _nonzero} ->
            {:error, error_msg}
        end

      {error_msg, _nonzero_exitcode} ->
        Logger.warn(
          "failed to create network '#{name}': could not create bridge interface: #{error_msg}"
        )
    end
  end

  defp ifconfig_loopback_create(if_name) do
    if Utils.interface_exists(if_name) do
      Utils.destroy_interface(if_name)
    end

    System.cmd("ifconfig", ["lo", "create", "name", if_name])
  end

  defp connected_to_host_network?(container_id) do
    case MetaData.connected_networks(container_id) do
      [%Schemas.Network{id: "host"}] -> true
      _ -> false
    end
  end

  def connected_to_loopback_networks?(container_id) do
    MetaData.connected_networks(container_id)
    |> Enum.any?(fn
      %Schemas.Network{driver: "loopback"} -> true
      _ -> false
    end)
  end

  def connected_to_vnet_networks?(container_id) do
    MetaData.connected_networks(container_id)
    |> Enum.any?(fn
      %Schemas.Network{driver: "vnet"} -> true
      _ -> false
    end)
  end

  def detect_gateway_if() do
    {output_json, 0} = System.cmd("netstat", ["--libxo", "json", "-rn"])
    # IO.puts(Jason.Formatter.pretty_print(output_json))
    {:ok, output} = Jason.decode(output_json)
    routing_table = output["statistics"]["route-information"]["route-table"]["rt-family"]

    # Extract the routes for ipv4
    [%{"rt-entry" => routes}] =
      Enum.filter(
        routing_table,
        # Selecting for "Internet6" gives the ipv6 routes
        fn %{"address-family" => addr_fam} -> addr_fam == "Internet" end
      )

    # Extract the interface name of the default gateway
    %{"interface-name" => if_name} =
      Enum.find(routes, "", fn %{"destination" => dest} -> dest == "default" end)

    if_name
  end

  def add_jail_ip(container_id, ip) do
    ips = get_jail_ips(container_id)
    jail_modify_ips(container_id, [ip | ips])
  end

  def remove_jail_ips(container_id, ip) do
    ips = MapSet.new([ip])
    ips_old = MapSet.new(get_jail_ips(container_id))
    ips_new = MapSet.to_list(MapSet.difference(ips_old, ips))
    jail_modify_ips(container_id, ips_new)
  end

  defp get_jail_ips(container_id) do
    # jls --libxo json -v -j 83 produceres
    # {"__version": "2",
    #  "jail-information": {"jail": [{"jid":83,"hostname":"","path":"/zroot/jocker_basejail","name":"83","state":"ACTIVE","cpusetid":4, "ipv4_addrs": ["172.17.0.1","172.17.0.2"], "ipv6_addrs": []}]}
    # }
    case System.cmd("/usr/sbin/jls", ["--libxo", "json", "-v", "-j", container_id]) do
      {output_json, 0} ->
        {:ok, jail_info} = Jason.decode(output_json)
        [%{"ipv4_addrs" => ip_addrs}] = jail_info["jail-information"]["jail"]
        ip_addrs

      {error_msg, _error_code} ->
        Logger.warn("Could not retrieve jail-info on jail #{container_id}: '#{error_msg}'")
        []
    end
  end

  def jail_modify_ips(jail_name, ips) do
    ips = Enum.join(ips, ",")

    case System.cmd("/usr/sbin/jail", ["-m", "name=#{jail_name}", "ip4.addr=#{ips}"],
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {error, _} ->
        Logger.error("Some error occured while assigning IPs #{ips} to #{jail_name}: #{error}")
        :error
    end
  end

  defp ifconfig_remove_alias(ip, iface) do
    case System.cmd("ifconfig", [iface, "-alias", "#{ip}"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _} -> Logger.warn("Some error occured while removing #{ip} from #{iface}: #{error}")
    end
  end

  def ip_added?(ip, iface) do
    # netstat --libxo json -4 -n -I lo0
    # {"statistics":
    #   {"interface": [{"name":"lo0","flags":"0x8049","network":"127.0.0.0/8","address":"127.0.0.1","received-packets":0,"sent-packets":0}, {"name":"lo0","flags":"0x8049","network":"127.0.0.0/8","address":"127.0.0.2","received-packets":0,"sent-packets":0}]}
    # }

    {output_json, 0} = System.cmd("netstat", ["--libxo", "json", "-4", "-n", "-I", iface])
    {:ok, output} = Jason.decode(output_json)
    output = output["statistics"]["interface"]
    Enum.any?(output, &(&1["address"] == ip))
  end

  defp new_ip(%Schemas.Network{driver: "loopback", loopback_if: if_name, subnet: subnet}) do
    ips_in_use = ips_on_interface(if_name)
    %CIDR{:first => first_ip, :last => last_ip} = CIDR.parse(subnet)
    generate_ip(first_ip, last_ip, ips_in_use)
  end

  defp new_ip(%Schemas.Network{driver: "vnet", id: network_id, subnet: subnet}) do
    configs = MetaData.get_endpoint_configs_from_network(network_id)
    ips_in_use = MapSet.new(Enum.map(configs, & &1.ip_address))
    %CIDR{:first => first_ip, :last => last_ip} = CIDR.parse(subnet)
    first_ip = first_ip |> ip2int() |> (&(&1 + 1)).() |> int2ip()
    # next_ip = first_ip
    generate_ip(first_ip, last_ip, ips_in_use)
  end

  defp generate_ip(first_ip, last_ip, ips_in_use) do
    first_ip = ip2int(first_ip)
    last_ip = ip2int(last_ip)
    ips_in_use = MapSet.new(Enum.map(ips_in_use, &ip2int(&1)))
    next_ip = first_ip

    generate_ip_(first_ip, last_ip, next_ip, ips_in_use)
  end

  defp generate_ip_(_first_ip, last_ip, next_ip, _ips_in_use) when next_ip > last_ip do
    :out_of_ips
  end

  defp generate_ip_(first_ip, last_ip, next_ip, ips_in_use) do
    case MapSet.member?(ips_in_use, next_ip) do
      true ->
        generate_ip_(first_ip, last_ip, next_ip + 1, ips_in_use)

      false ->
        int2ip(next_ip)
    end
  end

  defp ips_on_interface(if_name) do
    {output_json, 0} = System.cmd("netstat", ["--libxo", "json", "-I", if_name])
    {:ok, output} = Jason.decode(output_json)

    output["statistics"]["interface"]
    |> Enum.map(& &1["address"])
    |> Enum.filter(&String.match?(&1, ~r"\."))
  end

  defp int2ip(n) do
    int2ip_(n, 3, [])
  end

  defp int2ip_(n, 0, prev) do
    [n | prev]
    |> Enum.reverse()
    |> List.to_tuple()
    |> :inet.ntoa()
    |> to_string()
  end

  defp int2ip_(n, order, prev) do
    x = floor(n / pow(order))
    n_next = n - x * pow(order)
    int2ip_(n_next, order - 1, [x | prev])
  end

  defp ip2int({a, b, c, d}) do
    d + c * pow(1) + b * pow(2) + a * pow(3)
  end

  defp ip2int(ip) do
    {:ok, {a, b, c, d}} = ip |> to_charlist() |> :inet.parse_address()
    ip2int({a, b, c, d})
  end

  defp pow(n) do
    :erlang.round(:math.pow(256, n))
  end
end
