defmodule Jocker.Engine.Network do
  use GenServer
  alias Jocker.Engine.Config
  alias Jocker.Engine.Utils
  alias Jocker.Engine.MetaData
  alias Jocker.Structs.Network
  require Logger
  require Record
  import Jocker.Engine.Records

  @type create_options() :: [create_option()]
  @type create_option() :: {:subnet, String.t()} | {:if_name, String.t()}
  @type driver_type() :: :loopback

  @default_pf_configuration """
  gw_if="<%= gw_if %>" # This should be the interface of your default gateway
  jocker_loopback_if="<%= loopback_name %>" # This should be your jocker loopback interface
  jocker_subnet="<%= subnet %>" # This should be the subnet used by jocker

  nat on $gw_if from $jocker_subnet to any -> ($gw_if)
  """

  defmodule Jocker.Engine.Network.State do
    defstruct pf_config_path: nil,
              gateway_interface: nil
  end

  alias Jocker.Engine.Network.State

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  ### Docker Engine style API's
  @spec create(String.t(), driver_type(), create_options()) ::
          {:ok, %Network{}} | {:error, String.t()}
  def create(name, driver, options) do
    GenServer.call(__MODULE__, {:create, name, driver, options})
  end

  def connect(container, network_id, options) do
    GenServer.call(__MODULE__, {:connect, container, network_id, options})
  end

  def disconnect(container, network_id) do
    GenServer.call(__MODULE__, {:disconnect, container, network_id})
  end

  def list() do
    GenServer.call(__MODULE__, :list)
  end

  def remove(idname) do
    GenServer.call(__MODULE__, {:remove, idname})
  end

  def inspect_(network_idname) do
    GenServer.call(__MODULE__, {:inspect, network_idname})
  end

  ### Callback functions
  @impl true
  def init([]) do
    pf_conf_path = Config.get("pf_config_path")
    default_network_name = Config.get("default_network_name")
    if_name = Config.get("default_loopback_name")
    subnet = Config.get("default_subnet")

    gateway =
      case Config.get("default_gateway_if") do
        nil ->
          detect_gateway_if()

        gw ->
          gw
      end

    if pf_conf_path == nil do
      Logger.error("Configration file must contain an entry called 'pf_conf_path'")
    end

    if not Utils.touch(pf_conf_path) do
      Logger.error("Unable to access Jockers PF configuration file located at #{pf_conf_path}")
    end

    if default_network_name != nil do
      case create_network(default_network_name, :loopback, if_name: if_name, subnet: subnet) do
        {:ok, _} -> :ok
        {:error, "network name is already taken"} -> :ok
        {:error, reason} -> Logger.warn("Could not initialize default network: #{reason}")
      end
    end

    # FIXME configure_pf(pf_conf_path, gateway)
    {:ok, %State{:pf_config_path => pf_conf_path, :gateway_interface => gateway}}
  end

  @impl true
  def handle_call({:create, name, driver, options}, _from, state) do
    case create_network(name, driver, options) do
      {:ok, network} ->
        {:reply, {:ok, network}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:connect, container_id_name, network_id_name, _options},
        _from,
        state
      ) do
    %Network{:name => network_name, :if_name => if_name} = MetaData.get_network(network_id_name)

    cont = MetaData.get_container(container_id_name)

    case cont do
      container(name: jail_name, running: true, networks: cont_networks) ->
        %{:ip_addresses => ip_addresses} = network = Map.get(cont_networks, network_name, [])
        {new_ip, network_upd} = new_ip(network)
        MetaData.add_network(network_upd)

        ifconfig_alias(if_name, new_ip)

        network = Map.put(network, :ip_addresses, [new_ip | ip_addresses])
        cont_networks = Map.put(cont_networks, network_name, network)

        jail_modify_ips(jail_name, cont_networks)
        MetaData.add_container(container(cont, networks: cont_networks))
        {:reply, :ok, state}

      container(running: false, networks: cont_networks) ->
        %{:ip_addresses => ip_addresses} = network = Map.get(cont_networks, network_name, [])
        {new_ip, network_upd} = new_ip(network)
        MetaData.add_network(network_upd)

        network = Map.put(network, :ip_addresses, [new_ip | ip_addresses])
        cont_networks = Map.put(cont_networks, network_name, network)

        MetaData.add_container(container(cont, networks: cont_networks))
        {:reply, :ok, state}

      :not_found ->
        {:reply, {:error, "container not found"}, state}
    end
  end

  def handle_call({:disconnect, container_idname, network_idname}, _from, state) do
    container(name: jail_name, networks: cont_networks) =
      cont = MetaData.get_container(container_idname)

    %Network{:id => network_id} = MetaData.get_network(network_idname)
    cont_networks = Map.delete(cont_networks, network_id)
    jail_modify_ips(jail_name, cont_networks)
    MetaData.add_container(container(cont, networks: cont_networks))
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    networks = MetaData.list_networks()
    {:reply, networks, state}
  end

  def handle_call({:remove, idname}, _from, state) do
    # FIXME: Deal with pf as well? Atm. the default network is hardcoded. Should be fixed!
    case MetaData.get_network(idname) do
      %Network{:id => id, :if_name => if_name} ->
        System.cmd("ifconfig", [if_name, "destroy"])
        MetaData.remove_network(id)
        {:reply, :ok, state}

      :not_found ->
        {:reply, {:error, "network not found."}, state}
    end
  end

  def handle_call({:inspect, idname}, _from, state) do
    network = MetaData.get_network(idname)
    {:reply, network, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  ##########################
  ### Internal functions ###
  ##########################
  def create_network(name, :loopback, options) do
    subnet = Keyword.get(options, :subnet)
    if_name = Keyword.get(options, :if_name)
    parsed_subnet = CIDR.parse(subnet)

    cond do
      MetaData.get_network(name) != :not_found ->
        {:error, "network name is already taken"}

      not is_map(parsed_subnet) or parsed_subnet.__struct__ != CIDR ->
        {:error, "invalid subnet"}

      true ->
        create_loopback_network(name, if_name, parsed_subnet)
    end
  end

  def create_network(_, _unknown_driver, _) do
    {:error, "Unknown driver"}
  end

  def jail_modify_ips(jail_name, networks) do
    all_ips = Enum.concat(Enum.map(Enum.to_list(networks), fn {_, l} -> l end))
    jail_modify_ips_(jail_name, all_ips)
  end

  def jail_modify_ips_(jail_name, ips) do
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

  def ifconfig_alias(iface, ip) do
    case System.cmd("ifconfig", [iface, "alias", "#{ip}/32"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {error, _} ->
        Logger.error("Some error occured while adding #{ip} to #{iface}: #{error}")
        :error
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
    Enum.any?(output, fn entry -> entry["address"] == ip end)
  end

  def configure_pf(pf_config_path, default_gw) do
    # FIXME: hardcoded to be "default" at the moment
    %Network{:if_name => if_name, :subnet => subnet} = MetaData.get_network("default")

    pf_conf =
      EEx.eval_string(@default_pf_configuration,
        gw_if: default_gw,
        loopback_name: if_name,
        subnet: subnet
      )

    case File.write(pf_config_path, pf_conf, [:write]) do
      :ok ->
        case System.cmd("/sbin/pfctl", ["-f", pf_config_path]) do
          {_, 0} ->
            :ok

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

  def create_loopback_network(
        name,
        if_name,
        %CIDR{first: ip_start, last: ip_end, hosts: _nhosts, mask: _mask}
      ) do
    ip_first = Enum.join(Tuple.to_list(ip_start), ".")
    ip_end = Enum.join(Tuple.to_list(ip_end), ".")

    case create_loopback_interface(if_name) do
      {_, 0} ->
        network = %Network{
          id: Utils.uuid(),
          name: name,
          first_ip: ip_first,
          last_ip: ip_end,
          if_name: if_name
        }

        MetaData.add_network(network)
        {:ok, network}

      {error_output, _exitcode} ->
        {:error, "ifconfig failed with output: #{error_output}"}
    end
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
  end

  def create_pf_conf() do
    # FIXME: hardcoded to default network.
    %Network{:if_name => if_name, :subnet => subnet, :default_gw_if => default_gw_if} =
      MetaData.get_network("default")

    EEx.eval_string(@default_pf_configuration,
      if_name: if_name,
      default_subnet: subnet,
      default_gw_if: default_gw_if
    )
  end

  defp create_loopback_interface(jocker_if) do
    Utils.destroy_interface(jocker_if)
    _jocker_if_out = jocker_if <> "\n"
    System.cmd("ifconfig", ["lo", "create", "name", jocker_if])
  end

  defp remove_from_if(ip, iface) do
    case System.cmd("ifconfig", [iface, "-alias", "#{ip}"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _} -> Logger.warn("Some error occured while removing #{ip} from #{iface}: #{error}")
    end
  end

  defp new_ip(%Network{first_ip: first_ip, last_ip: last_ip, in_use: ips_in_use} = network) do
    ips_in_use = Enum.map(ips_in_use, fn ip -> ip2int(ip) end)
    next_ip = Enum.max(ips_in_use)
    n_ips_used = length(ips_in_use)
    ips_in_use = MapSet.new(ips_in_use)
    last_ip = ip2int(last_ip)
    first_ip = ip2int(first_ip)

    case first_ip - last_ip do
      n when n > n_ips_used - 1 ->
        :out_of_ips

      _ ->
        {new_ip, ips_in_use} = new_ip_(first_ip, last_ip, next_ip, ips_in_use)
        ips_in_use = Enum.map(ips_in_use, fn ip -> int2ip(ip) end)
        {int2ip(new_ip), %Network{network | :in_use => ips_in_use}}
    end
  end

  defp new_ip_(first_ip, last_ip, next_ip, ips_in_use) when next_ip > last_ip do
    new_ip_(first_ip, last_ip, first_ip, ips_in_use)
  end

  defp new_ip_(first_ip, last_ip, next_ip, ips_in_use) do
    case MapSet.member?(ips_in_use, next_ip) do
      true ->
        new_ip_(first_ip, last_ip, next_ip + 1, ips_in_use)

      false ->
        new_ip = int2ip(next_ip)
        # ips_in_use_str = Enum.map(ips_in_use, fn ip -> ip2int(ip) end)
        {next_ip, MapSet.put(ips_in_use, new_ip)}
    end
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

  defp ip2int(ip) do
    {:ok, {a, b, c, d}} = ip |> to_charlist() |> :inet.parse_address()
    d + c * pow(1) + b * pow(2) + a * pow(3)
  end

  defp pow(n) do
    :erlang.round(:math.pow(256, n))
  end
end
