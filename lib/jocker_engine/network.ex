defmodule Jocker.Structs.EndPointConfig do
  @derive Jason.Encoder
  defstruct id: nil,
            name: nil,
            subnet: nil,
            if_name: nil,
            ip_addresses: [],
            default_gw_if: nil
end

defmodule Jocker.Engine.Network do
  use GenServer
  alias Jocker.Engine.Config
  alias Jocker.Engine.Utils
  alias Jocker.Engine.MetaData
  alias Jocker.Structs.EndPointConfig
  alias Jocker.Structs.Network
  require Logger
  require Record
  import Jocker.Engine.Records

  @type create_options() :: [create_option()]
  @type create_option() :: {:subnet, String.t()} | {:if_name, String.t()}
  @type driver_type() :: :loopback
  @type network_id() :: String.t()
  @type endpoint_config() :: %EndPointConfig{}

  @default_pf_configuration """
  # This is the pf(4) configuration file template that is used by Jocker.
  # Feel free to add additional rules as long as the tags (and their ordering) below are preserved.
  # Modify with care: It can potentially affect Jocker in unpredictable ways.
  # The resulting configuration file that is loaded into pf is defined at the 'pf_config_path'
  # entry in the jocker engine configuration file (jocker_config.yaml).

  # Jockers macros STARTS here
  <%= jocker_macros %>
  # Jockers macros ENDS here

  # Jockers translation rules STARTS here
  <%= jocker_translation %>
  # Jockers translation rules END here

  # Jockers filtering rules STARTS here
  <%= jocker_filtering %>
  # Jockers filtering rules ENDS here
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

  def connect(container, network_id) do
    GenServer.call(__MODULE__, {:connect, container, network_id})
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

    create_interfaces()
    state = %State{:pf_config_path => pf_conf_path, :gateway_interface => gateway}

    if default_network_name != nil do
      case create_network(default_network_name, :loopback, state, if_name: if_name, subnet: subnet) do
        {:ok, _} -> :ok
        {:error, "network name is already taken"} -> :ok
        {:error, reason} -> Logger.warn("Could not initialize default network: #{reason}")
      end
    end

    configure_pf(pf_conf_path, gateway)
    {:ok, state}
  end

  @impl true
  def handle_call({:create, name, driver, options}, _from, state) do
    reply = create_network(name, driver, state, options)
    {:reply, reply, state}
  end

  def handle_call(
        {:connect, container_id_name, network_id_name},
        _from,
        state
      ) do
    network = MetaData.get_network(network_id_name)
    cont = MetaData.get_container(container_id_name)
    {:reply, reply} = connect_container(network, cont)
    {:reply, reply, state}
  end

  def handle_call({:disconnect, container_idname, network_idname}, _from, state) do
    container(name: jail_name, networking_config: networking_config) =
      cont = MetaData.get_container(container_idname)

    # Remove ip-addresses from the network interface
    %Network{:id => network_id, :if_name => if_name} = MetaData.get_network(network_idname)
    %{:ip_addresses => ip_addresses} = Map.get(networking_config, network_id)
    Enum.map(ip_addresses, &ifconfig_remove_alias(&1, if_name))

    # Delete the containers endpoint-config entry in its networking config
    networking_config = Map.delete(networking_config, network_id)
    jail_modify_ips(jail_name, networking_config)
    MetaData.add_container(container(cont, networking_config: networking_config))
    {:reply, :ok, state}
  end

  def handle_call(:list, _from, state) do
    networks = MetaData.list_networks()
    {:reply, networks, state}
  end

  def handle_call({:remove, idname}, _from, state) do
    case MetaData.get_network(idname) do
      %Network{:id => id, :if_name => if_name} ->
        Utils.destroy_interface(if_name)
        MetaData.remove_network(id)
        configure_pf(state.pf_config_path, state.gateway_interface)
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
  def create_network(name, :loopback, state, options) do
    subnet = Keyword.get(options, :subnet)
    if_name = Keyword.get(options, :if_name)
    parsed_subnet = CIDR.parse(subnet)

    cond do
      MetaData.get_network(name) != :not_found ->
        {:error, "network name is already taken"}

      not is_map(parsed_subnet) or parsed_subnet.__struct__ != CIDR ->
        {:error, "invalid subnet"}

      true ->
        {:ok, network} = create_loopback_network(name, if_name, subnet)
        configure_pf(state.pf_config_path, state.gateway_interface)
        {:ok, network}
    end
  end

  def create_network(_, _unknown_driver, _, _) do
    {:error, "Unknown driver"}
  end

  defp connect_container(
         %Network{:id => network_id, :if_name => if_name} = network,
         container(name: name, running: running, networking_config: networking_config) = cont
       ) do
    case Map.get(networking_config, network_id, :did_not_exist) do
      :did_not_exist ->
        ip = new_ip(network)
        ifconfig_alias(if_name, ip)

        new_networking_config =
          Map.put(networking_config, network_id, %EndPointConfig{ip_addresses: [ip]})

        if running do
          jail_modify_ips(name, new_networking_config)
        end

        MetaData.add_container(container(cont, networking_config: new_networking_config))
        {:reply, :ok}

      %EndPointConfig{} ->
        {:reply, {:error, "Endpoint configuration already exists for #{name}"}}
    end
  end

  defp connect_container(_network, :not_found) do
    Logger.warn("Could not connect container to network: container not found")
    {:reply, {:error, "container not found"}}
  end

  defp connect_container(:not_found, _container) do
    Logger.warn("Could not connect container to network: network not found")
    {:reply, {:error, "network not found"}}
  end

  defp connect_container(network, container) do
    Logger.warn(
      "No matches for network '#{inspect(network)}' and container '#{inspect(container)}'"
    )
  end

  def configure_pf(pf_config_path, default_gw) do
    networks = MetaData.list_networks()

    state = %{
      :macros => [
        "gw_if=\"#{default_gw}\" # This should be the interface of your default gateway"
      ],
      :translation => [],
      :filtering => []
    }

    pf_config = create_pf_config(networks, state)
    load_pf_config(pf_config_path, pf_config)
  end

  def create_pf_config(
        [%Network{:if_name => if_name, :subnet => subnet} | rest],
        %{:macros => macros, :translation => translation} = state
      ) do
    new_macro = "jocker_#{if_name}_subnet=\"#{subnet}\""
    nat_subnet = "nat on $gw_if from $jocker_#{if_name}_subnet to any -> ($gw_if)"

    new_state = %{
      state
      | :macros => [new_macro | macros],
        :translation => [nat_subnet | translation]
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

  def load_pf_config(pf_config_path, config) do
    case File.write(pf_config_path, config, [:write]) do
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

  defp create_interfaces() do
    MetaData.list_networks()
    |> Enum.map(fn %Network{:if_name => if_name} ->
      create_loopback_interface(if_name, :overwrite)
    end)
  end

  def create_loopback_network(
        name,
        if_name,
        subnet
      ) do
    case create_loopback_interface(if_name, :no_overwrite) do
      {_, 0} ->
        network = %Network{
          id: Utils.uuid(),
          name: name,
          subnet: subnet,
          if_name: if_name
        }

        MetaData.add_network(network)
        {:ok, network}

      {error_output, _exitcode} ->
        {:error, "ifconfig failed with output: #{error_output}"}
    end
  end

  defp create_loopback_interface(jocker_if, mode \\ :no_overwrite) do
    if mode == :overwrite do
      Utils.destroy_interface(jocker_if)
    end

    if not Utils.interface_exists(jocker_if) do
      System.cmd("ifconfig", ["lo", "create", "name", jocker_if])
    else
      {"", 0}
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

    if_name
  end

  def jail_modify_ips(jail_name, networking_config) do
    all_ips =
      Map.values(networking_config)
      |> Enum.map(& &1[:ip_addresses])
      |> Enum.concat()

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

  defp new_ip(%Network{if_name: if_name, subnet: subnet}) do
    ips_in_use = ips_on_interface(if_name)
    n_ips_used = length(ips_in_use)
    ips_in_use = MapSet.new(Enum.map(ips_in_use, &ip2int(&1)))

    %CIDR{:last => last, :first => first} = CIDR.parse(subnet)
    last_ip = ip2int(last)
    first_ip = ip2int(first)

    case first_ip - last_ip do
      n when n > n_ips_used - 1 ->
        :out_of_ips

      _ ->
        next_ip = first_ip
        new_ip_(first_ip, last_ip, next_ip, ips_in_use)
    end
  end

  defp new_ip_(_first_ip, last_ip, next_ip, _ips_in_use) when next_ip > last_ip do
    :out_of_ips
  end

  defp new_ip_(first_ip, last_ip, next_ip, ips_in_use) do
    case MapSet.member?(ips_in_use, next_ip) do
      true ->
        new_ip_(first_ip, last_ip, next_ip + 1, ips_in_use)

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
