defmodule Kleened.Core.Network do
  use GenServer
  alias Kleened.Core.{Config, Container, Utils, MetaData, OS, FreeBSD}
  alias Kleened.API.Schemas
  require Logger

  alias __MODULE__, as: Network

  @type t() :: %Schemas.Network{}
  @type network_id() :: String.t()
  @type network_config() :: %Schemas.NetworkConfig{}
  @type endpoint() :: %Schemas.EndPoint{}
  @type protocol() :: String.t()

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  ### Docker Core style API's
  @spec create(network_config()) ::
          {:ok, Network.t()} | {:error, String.t()}
  def create(config) do
    GenServer.call(__MODULE__, {:create, config})
  end

  @spec connect(String.t(), %Schemas.EndPointConfig{}) ::
          {:ok, endpoint()} | {:error, String.t()}
  def connect(network_idname, config) do
    GenServer.call(__MODULE__, {:connect, network_idname, config}, 30_000)
  end

  @spec connect(String.t(), String.t()) :: :ok | {:error, String.t()}
  def disconnect(container_idname, network_idname) do
    GenServer.call(__MODULE__, {:disconnect, container_idname, network_idname})
  end

  @spec disconnect_all(String.t()) :: :ok
  def disconnect_all(container_id) do
    GenServer.call(__MODULE__, {:disconnect_all, container_id})
  end

  @spec list() :: [Network.t()]
  def list() do
    GenServer.call(__MODULE__, :list)
  end

  @spec remove(String.t()) :: {:ok, Network.network_id()} | {:error, String.t()}
  def remove(idname) do
    GenServer.call(__MODULE__, {:remove, idname}, 30_000)
  end

  @spec prune() :: {:ok, [Network.network_id()]}
  def prune() do
    GenServer.call(__MODULE__, :prune, 30_000)
  end

  @spec inspect_(String.t()) :: {:ok, %Schemas.NetworkInspect{}} | {:error, String.t()}
  def inspect_(network_idname) do
    GenServer.call(__MODULE__, {:inspect, network_idname})
  end

  def inspect_endpoint(container_id, network_id) do
    GenServer.call(__MODULE__, {:inspect_endpoint, container_id, network_id})
  end

  @spec validate_pubports([%Schemas.PublishedPort{}]) :: :ok | {:error, String.t()}
  def validate_pubports([pub_port | rest]) do
    with :ok <- verify_port_value(pub_port.host_port, :source),
         :ok <- verify_port_value(pub_port.container_port, :dest) do
      validate_pubports(rest)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_pubports([]) do
    :ok
  end

  defp verify_port_value(port_raw, type) do
    case {type, String.split(port_raw, ":")} do
      {_, [port]} ->
        is_integers?([port])

      {:dest, [port, "*"]} ->
        is_integers?([port])

      {_, ports} when length(ports) == 2 ->
        is_integers?(ports)

      _ ->
        {:error, "could not decode port publishing specification"}
    end
  end

  defp is_integers?(ports) do
    result =
      ports
      |> Enum.map(fn port_str ->
        case Integer.parse(port_str) do
          {port, ""} when 0 <= port and port <= 65535 -> true
          _ -> false
        end
      end)
      |> Enum.all?()

    case result do
      true -> :ok
      false -> {:error, "invalid port value (should be in the range 0 - 65535)"}
    end
  end

  ### Callback functions
  @impl true
  def init([]) do
    FreeBSD.enable_ip_forwarding()

    create_network_interfaces()
    state = %{}

    enable_pf()
    configure_pf()
    {:ok, state}
  end

  @impl true
  def handle_call({:create, config}, _from, state) do
    reply =
      case validate_create_config(config) do
        :ok -> create_(config, state)
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:connect, net_ident, %Schemas.EndPointConfig{container: con_ident} = config},
        _from,
        state
      ) do
    reply =
      with {:container, %Schemas.Container{} = container} <-
             {:container, MetaData.get_container(con_ident)},
           {:network, %Schemas.Network{} = network} <-
             {:network, MetaData.get_network(net_ident)},
           {:endpoint, :not_found} <-
             {:endpoint, MetaData.get_endpoint(container.id, network.id)},
           {:ok, endpoint} <- connect_with_driver(container, network, config) do
        configure_pf()
        {:ok, endpoint}
      else
        {:network, :not_found} ->
          Logger.debug(
            "cannot connect container #{config.container} to #{net_ident}: network not found"
          )

          {:error, "network not found"}

        {:container, :not_found} ->
          Logger.debug(
            "cannot connect container #{config.container} to #{net_ident}: container not found"
          )

          {:error, "container not found"}

        {:endpoint, _} ->
          {:error, "container already connected to the network"}

        {:error, msg} ->
          {:error, msg}
      end

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
    networks = MetaData.list_networks()
    {:reply, networks, state}
  end

  def handle_call({:remove, identifier}, _from, state) do
    reply = remove_(identifier)
    {:reply, reply, state}
  end

  def handle_call(:prune, _from, state) do
    pruned_networks = MetaData.list_unused_networks()
    pruned_networks |> Enum.map(&remove_(&1))
    {:reply, {:ok, pruned_networks}, state}
  end

  def handle_call({:inspect, idname}, _from, state) do
    reply =
      case MetaData.get_network(idname) do
        :not_found ->
          {:error, "network not found"}

        network ->
          endpoints = MetaData.get_endpoints_from_network(network.id)
          {:ok, %Schemas.NetworkInspect{network: network, network_endpoints: endpoints}}
      end

    {:reply, reply, state}
  end

  def handle_call({:inspect_endpoint, container_id, network_id}, _from, state) do
    endpoint = MetaData.get_endpoint(container_id, network_id)
    {:reply, endpoint, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  ##########################
  ### Internal functions ###
  ##########################
  def validate_create_config(%Schemas.NetworkConfig{
        name: name,
        subnet: subnet,
        subnet6: subnet6,
        gateway: gateway,
        gateway6: gateway6
      }) do
    with {:subnet, :ok} <- {:subnet, validate_ip(subnet, :subnet)},
         {:subnet6, :ok} <- {:subnet6, validate_ip(subnet6, :subnet6)},
         {:gateway, :ok} <- {:gateway, validate_ip(gateway, :gateway)},
         {:gateway6, :ok} <- {:gateway6, validate_ip(gateway6, :gateway6)},
         :not_found <- MetaData.get_network(name) do
      :ok
    else
      %Schemas.Network{} ->
        {:error, "network name is already taken"}

      {:subnet, {:error, reason}} ->
        {:error, "invalid subnet: #{reason}"}

      {:subnet6, {:error, reason}} ->
        {:error, "invalid subnet6: #{reason}"}

      {:gateway, {:error, reason}} ->
        {:error, "invalid gateway: #{reason}"}

      {:gateway6, {:error, reason}} ->
        {:error, "invalid gateway6: #{reason}"}
    end
  end

  defp create_(
         %Schemas.NetworkConfig{
           interface: ""
         } = config,
         state
       ) do
    interface = generate_interface_name()
    create_(%Schemas.NetworkConfig{config | interface: interface}, state)
  end

  defp create_(
         %Schemas.NetworkConfig{
           nat: "<host-gateway>"
         } = config,
         state
       ) do
    case host_gateway_interface() do
      {:ok, nat_if} ->
        create_(%Schemas.NetworkConfig{config | nat: nat_if}, state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_(
         %Schemas.NetworkConfig{type: "loopback"} = config,
         state
       ) do
    create_interface("lo", config.interface)
    {:ok, config} = configure_gateways(config)
    network = create_network_metadata(config, state)
    configure_pf()
    {:ok, network}
  end

  defp create_(
         %Schemas.NetworkConfig{type: "bridge"} = config,
         state
       ) do
    create_interface("bridge", config.interface)
    {:ok, config} = configure_gateways(config)
    network = create_network_metadata(config, state)
    configure_pf()
    {:ok, network}
  end

  defp create_(
         %Schemas.NetworkConfig{type: "custom"} = config,
         state
       ) do
    {:ok, config} = configure_gateways(config)
    network = create_network_metadata(config, state)
    configure_pf()
    {:ok, network}
  end

  defp create_(%Schemas.NetworkConfig{type: driver}, _state) do
    {:error, "Unknown driver #{inspect(driver)}"}
  end

  defp create_network_interfaces() do
    MetaData.list_networks()
    |> Enum.map(fn
      %Schemas.Network{type: "bridge", interface: interface} ->
        create_interface("bridge", interface)

      %Schemas.Network{type: "loopback", interface: interface} ->
        create_interface("lo", interface)

      _ ->
        :ok
    end)
  end

  defp configure_gateways(
         %Schemas.NetworkConfig{
           type: "bridge",
           gateway: "<auto>",
           subnet: ""
         } = config
       ) do
    configure_gateways(%Schemas.NetworkConfig{config | gateway: ""})
  end

  defp configure_gateways(
         %Schemas.NetworkConfig{
           type: "bridge",
           gateway: "<auto>",
           subnet: subnet
         } = config
       )
       when subnet != "" do
    gateway = first_ip_address(config.subnet, "inet")

    case ifconfig_cidr_alias(gateway, config.subnet, config.interface, "inet") do
      :ok -> configure_gateways(%Schemas.NetworkConfig{config | gateway: gateway})
      {:error, output} -> {:error, output}
    end
  end

  defp configure_gateways(
         %Schemas.NetworkConfig{
           type: "bridge",
           gateway6: "<auto>",
           subnet6: ""
         } = config
       ) do
    configure_gateways(%Schemas.NetworkConfig{config | gateway6: ""})
  end

  defp configure_gateways(
         %Schemas.NetworkConfig{
           type: "bridge",
           gateway6: "<auto>",
           subnet6: subnet6
         } = config
       )
       when subnet6 != "" do
    gateway6 = first_ip_address(config.subnet6, "inet6")

    case ifconfig_cidr_alias(gateway6, config.subnet6, config.interface, "inet6") do
      :ok -> configure_gateways(%Schemas.NetworkConfig{config | gateway6: gateway6})
      {:error, output} -> {:error, output}
    end
  end

  defp configure_gateways(config) do
    {:ok, config}
  end

  def create_interface(if_type, interface) do
    if interface_exists(interface) do
      destroy_interface(interface)
    end

    OS.cmd(~w"ifconfig #{if_type} create name #{interface}")
  end

  defp create_network_metadata(
         %Schemas.NetworkConfig{
           name: name,
           type: type,
           subnet: subnet,
           subnet6: subnet6,
           interface: interface,
           gateway: gateway,
           gateway6: gateway6,
           nat: nat,
           icc: icc,
           internal: internal
         },
         _state
       ) do
    network = %Schemas.Network{
      id: Utils.uuid(),
      name: name,
      type: type,
      subnet: subnet,
      subnet6: subnet6,
      interface: interface,
      gateway: gateway,
      gateway6: gateway6,
      nat: nat,
      icc: icc,
      internal: internal
    }

    MetaData.add_network(network)
    network
  end

  defp remove_(idname) do
    case MetaData.get_network(idname) do
      %Schemas.Network{type: "custom"} = network ->
        _remove_metadata_and_pf(network)
        {:ok, network.id}

      %Schemas.Network{type: "loopback"} = network ->
        _remove_metadata_and_pf(network)
        destroy_interface(network.interface)
        {:ok, network.id}

      %Schemas.Network{type: "bridge"} = network ->
        _remove_metadata_and_pf(network)
        # Just in case there are more members added:
        remove_bridge_members(network.interface)
        destroy_interface(network.interface)
        {:ok, network.id}

      :not_found ->
        {:error, "network not found."}
    end
  end

  def _remove_metadata_and_pf(%Schemas.Network{id: id}) do
    container_ids = MetaData.connected_containers(id)
    Enum.map(container_ids, &disconnect_(&1, id))
    MetaData.remove_network(id)
    configure_pf()
  end

  defp connect_with_driver(%Schemas.Container{network_driver: "disabled"}, _network, _config) do
    {:error, "containers with the 'disabled' network-driver cannot connect to networks."}
  end

  defp connect_with_driver(%Schemas.Container{network_driver: "host"}, _network, _config) do
    {:error, "containers with the 'host' network-driver cannot connect to networks."}
  end

  defp connect_with_driver(
         %Schemas.Container{network_driver: "vnet"},
         %Schemas.Network{type: type},
         _config
       )
       when type == "loopback" or type == "custom" do
    {:error, "containers using the 'vnet' network-driver can't connect to #{type} networks"}
  end

  defp connect_with_driver(
         %Schemas.Container{network_driver: "ipnet"} = container,
         network,
         %Schemas.EndPointConfig{ip_address: ipv4_addr, ip_address6: ipv6_addr}
       ) do
    with {:ok, ip_address} <- create_ip_address(ipv4_addr, network, "inet"),
         {:ok, ip_address6} <- create_ip_address(ipv6_addr, network, "inet6"),
         :ok <- add_container_ip_alias(ip_address, container, network, "inet"),
         :ok <- add_container_ip_alias(ip_address6, container, network, "inet6") do
      endpoint = %Schemas.EndPoint{
        id: Utils.uuid(),
        network_id: network.name,
        container_id: container.id,
        ip_address: ip_address,
        ip_address6: ip_address6
      }

      MetaData.add_endpoint(container.id, network.id, endpoint)
      {:ok, endpoint}
    else
      {:error, msg} -> {:error, msg}
    end
  end

  defp connect_with_driver(
         %Schemas.Container{network_driver: "vnet"} = container,
         %Schemas.Network{type: "bridge"} = network,
         %Schemas.EndPointConfig{ip_address: ipv4_addr, ip_address6: ipv6_addr}
       ) do
    with {:running, false} <- {:running, Container.is_running?(container.id)},
         {:ok, ip_address} <- create_ip_address(ipv4_addr, network, "inet"),
         {:ok, ip_address6} <- create_ip_address(ipv6_addr, network, "inet6") do
      endpoint = %Schemas.EndPoint{
        id: Utils.uuid(),
        network_id: network.name,
        container_id: container.id,
        ip_address: ip_address,
        ip_address6: ip_address6
      }

      MetaData.add_endpoint(container.id, network.id, endpoint)
      {:ok, endpoint}
    else
      {:error, msg} -> {:error, msg}
      # NOTE: Does even matter? We can still set meta-data and then it should work on a restart.
      {:running, true} -> {:error, "cannot connect a running vnet container to a network"}
    end
  end

  defp connect_with_driver(container, network, _config) do
    Logger.warn(
      "Unknown error occured when connecting container '#{container.id}' to network '#{network.id}'"
    )

    {:error, "unknown error"}
  end

  def disconnect_(con_ident, net_ident) do
    with {:container, container = %Schemas.Container{}} <-
           {:container, MetaData.get_container(con_ident)},
         {:network, network = %Schemas.Network{}} <- {:network, MetaData.get_network(net_ident)},
         {:endpoint, config = %Schemas.EndPoint{}} <-
           {:endpoint, MetaData.get_endpoint(container.id, network.id)} do
      cond do
        container.network_driver == "ipnet" ->
          # Remove ip-addresses from the jail, network interface, and database
          ifconfig_alias_remove(config.ip_address, network.interface, "inet")
          ifconfig_alias_remove(config.ip_address6, network.interface, "inet6")

          if Container.is_running?(container.id) do
            remove_jail_ips(container.id, config.ip_address)
          end

          MetaData.remove_endpoint_config(container.id, network.id)

        container.network_driver == "vnet" ->
          if config.epair != nil do
            FreeBSD.destroy_bridged_vnet_epair(config.epair, network.interface, container.id)
          end

          MetaData.remove_endpoint_config(container.id, network.id)

        true ->
          Logger.warn("this should not happen!")
          {:error, "unknown error occured"}
      end
    else
      {:container, :not_found} -> {:error, "container not found"}
      {:network, :not_found} -> {:error, "network not found"}
      {:endpoint, :not_found} -> {:error, "endpoint configuration not found"}
    end
  end

  @spec create_ip_address(String.t(), %Schemas.Network{}, protocol()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp create_ip_address("", _network, _protocol) do
    {:ok, ""}
  end

  defp create_ip_address("<auto>", %Schemas.Network{subnet: ""}, "inet") do
    {:ok, ""}
  end

  defp create_ip_address("<auto>", %Schemas.Network{subnet6: ""}, "inet6") do
    {:ok, ""}
  end

  defp create_ip_address(_ip_address, %Schemas.Network{subnet: ""}, "inet") do
    {:error, "cannot set ip address because there is no IPv4 subnet defined for this network"}
  end

  defp create_ip_address(_ip_address, %Schemas.Network{subnet6: ""}, "inet6") do
    {:error, "cannot set ip address because there is no IPv6 subnet defined for this network"}
  end

  defp create_ip_address("<auto>", network, protocol) do
    case new_ip(network, protocol) do
      :out_of_ips ->
        {:error, "no more #{protocol} IP's left in the network"}

      ip_address ->
        create_ip_address(ip_address, network, protocol)
    end
  end

  defp create_ip_address(ip_address, _network, protocol) do
    case decode_ip(ip_address, protocol) do
      {:error, msg} ->
        {:error, "could not parse #{protocol} address #{ip_address}: #{msg}"}

      {:ok, _ip_tuple} ->
        {:ok, ip_address}
    end
  end

  @spec add_container_ip_alias(String.t(), %Schemas.Container{}, %Schemas.Network{}, protocol) ::
          :ok | {:error, String.t()}
  defp add_container_ip_alias("", _container, _network, _protocol) do
    :ok
  end

  defp add_container_ip_alias(ip_address, container, network, protocol) do
    netmask =
      case protocol do
        "inet" -> "32"
        "inet6" -> "128"
      end

    case OS.cmd(~w"ifconfig #{network.interface} #{protocol} #{ip_address}/#{netmask} alias") do
      {_, 0} ->
        if Container.is_running?(container.id) do
          add_jail_ip(container.id, ip_address)
        end

        :ok

      {error_output, _nonzero_exitcode} ->
        {:error, "could not add ip #{ip_address} to #{network.interface}: #{error_output}"}
    end
  end

  def decode_ip(ip, protocol) do
    ip_charlist = String.to_charlist(ip)

    case protocol do
      "inet" -> :inet.parse_ipv4_address(ip_charlist)
      "inet6" -> :inet.parse_ipv6_address(ip_charlist)
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

  def configure_pf() do
    case create_pf_config() do
      {:ok, pf_config} ->
        load_pf_config(pf_config)

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp prefix(network_id) do
    "kleenet_#{network_id}"
  end

  defp create_pf_config() do
    networks = MetaData.list_networks()
    containers = MetaData.list_containers()

    state = %{
      :macros => host_gw_macro() ++ network_interfaces_macro(networks),
      :translation => [],
      :filtering => []
    }

    state = create_pf_network_config(networks, state)
    state = create_pf_public_ports_config(containers, state)
    render_pf_config(state)
  end

  defp create_pf_public_ports_config(
         [%{public_ports: public_ports} = container | rest],
         state
       ) do
    endpoints = MetaData.get_endpoints_from_container(container.id)
    ip4 = extract_ip(endpoints, "inet")
    ip6 = extract_ip(endpoints, "inet6")

    update_port = fn
      pub_port, ip4, "inet" -> %Schemas.PublishedPort{pub_port | ip_address: ip4}
      pub_port, ip6, "inet6" -> %Schemas.PublishedPort{pub_port | ip_address6: ip6}
    end

    new_pub_ports =
      case {ip4, ip6} do
        {"", ""} ->
          public_ports

        {ip4, ""} ->
          public_ports |> Enum.map(&update_port.(&1, ip4, "inet"))

        {"", ip6} ->
          public_ports |> Enum.map(&update_port.(&1, ip6, "inet6"))

        {ip4, ip6} ->
          public_ports
          |> Enum.map(&update_port.(&1, ip4, "inet"))
          |> Enum.map(&update_port.(&1, ip6, "inet6"))
      end

    MetaData.add_container(%Schemas.Container{container | public_ports: new_pub_ports})
    new_state = create_pf_port_config(new_pub_ports, state)
    create_pf_public_ports_config(rest, new_state)
  end

  defp create_pf_public_ports_config([], state) do
    state
  end

  defp create_pf_port_config([pub_port | rest], state) do
    updated_translation = state.translation ++ port_translation(pub_port)
    updated_filtering = state.filtering ++ port_filtering(pub_port)

    new_state = %{
      state
      | translation: updated_translation,
        filtering: updated_filtering
    }

    create_pf_port_config(rest, new_state)
  end

  defp create_pf_port_config([], state) do
    state
  end

  defp port_translation(
         %Schemas.PublishedPort{
           interfaces: interfaces,
           ip_address: ip4,
           ip_address6: ip6,
           host_port: host_port,
           container_port: port,
           protocol: proto
         } = pub_port
       ) do
    ip4_translation =
      for interface <- interfaces,
          do:
            "rdr on #{interface} inet proto #{proto} from any to (#{interface}) port #{host_port} -> #{
              ip4
            } port #{port}"

    ip6_translation =
      for interface <- interfaces,
          do:
            "rdr on #{interface} inet proto #{proto} from any to (#{interface}) port #{host_port} -> #{
              ip6
            } port #{port}"

    use_necessary_ip_protocols(pub_port, ip4_translation, ip6_translation)
  end

  defp port_filtering(
         %Schemas.PublishedPort{
           interfaces: interfaces,
           ip_address: ip4,
           ip_address6: ip6,
           host_port: host_port,
           container_port: port,
           protocol: protocol
         } = pub_port
       ) do
    port = format_container_port(host_port, port)

    ip4_port_pass =
      Enum.map(interfaces, fn interface ->
        "pass quick on #{interface} proto #{protocol} from any to #{ip4} port #{port}"
      end) ++
        [
          "pass quick on $kleenet_network_interfaces inet proto tcp from any to #{ip4} port #{
            port
          }"
        ]

    ip6_port_pass =
      Enum.map(interfaces, fn interface ->
        "pass quick on #{interface} proto #{protocol} from any to #{ip6} port #{port}"
      end) ++
        [
          "pass quick on $kleenet_network_interfaces inet proto tcp from any to #{ip6} port #{
            port
          }"
        ]

    use_necessary_ip_protocols(pub_port, ip4_port_pass, ip6_port_pass)
  end

  defp format_container_port(host_port, port) do
    case String.split(port, ":") do
      [port_start, "*"] ->
        case String.split(host_port, ":") do
          # There is only source port, so '<port>:*' just evaluates to '<port>'
          [_one_host_port] ->
            [port_start]

          [host_port_start, host_port_end] ->
            range = String.to_integer(host_port_end) - String.to_integer(host_port_start)
            port_end = String.to_integer(port_start) + range
            "#{port_start}:#{port_end}"
        end

      _ ->
        port
    end
  end

  def extract_ip([endpoint | rest], ip_type) do
    case select_ip(endpoint, ip_type) do
      non_ip when is_nil(non_ip) or non_ip == "" ->
        extract_ip(rest, ip_type)

      ip ->
        ip
    end
  end

  def extract_ip([], _ip_type) do
    ""
  end

  defp select_ip(endpoint, "inet") do
    endpoint.ip_address
  end

  defp select_ip(endpoint, "inet6") do
    endpoint.ip_address6
  end

  defp create_pf_network_config([network | rest], state) do
    updated_macros = state.macros ++ network_macros(network)
    updated_translation = state.translation ++ network_translation(network)

    updated_filtering =
      state.filtering ++
        block_incoming_traffic_to_network(network) ++ network_filtering(network)

    new_state = %{
      state
      | macros: updated_macros,
        translation: updated_translation,
        filtering: updated_filtering
    }

    create_pf_network_config(rest, new_state)
  end

  defp create_pf_network_config([], state) do
    state
  end

  defp render_pf_config(%{
         :macros => macros,
         :translation => translation,
         :filtering => filtering
       }) do
    template_path = Config.get("pf_config_template_path")

    case File.read(template_path) do
      {:ok, config_template} ->
        config =
          EEx.eval_string(config_template,
            kleene_macros: Enum.join(macros, "\n"),
            kleene_translation: Enum.join(translation, "\n"),
            kleene_filtering: Enum.join(filtering, "\n")
          )

        {:ok, config}

      {:error, msg} ->
        Logger.error("could not read the pf.conf-template  at #{template_path}: #{msg}")
        {:error, msg}
    end
  end

  defp block_incoming_traffic_to_network(network) do
    {subnet, subnet6, _interface, _nat_interface, _host_gateway_interface} =
      defined_network_macros(network.id)

    ipv4_rule = "block in log from any to #{subnet}"
    ipv6_rule = "block in log from any to #{subnet6}"

    use_necessary_ip_protocols(network, [ipv4_rule], [ipv6_rule])
  end

  defp network_filtering(%Schemas.Network{internal: false, icc: true} = network) do
    use_necessary_ip_protocols(network, [icc_allow(network, "inet")], [
      icc_allow(network, "inet6")
    ])
  end

  defp network_filtering(%Schemas.Network{internal: false, icc: false} = network) do
    use_necessary_ip_protocols(network, [], [])
  end

  defp network_filtering(%Schemas.Network{internal: true, icc: true, nat: ""} = network) do
    {subnet, subnet6, _interface, _nat_interface, host_gateway_interface} =
      defined_network_macros(network.id)

    ipv4_internal_nat_rule = "block out quick log on #{host_gateway_interface} from #{subnet}"
    ipv6_internal_nat_rule = "block out quick log on #{host_gateway_interface} from #{subnet6}"

    use_necessary_ip_protocols(
      network,
      [icc_allow(network, "inet"), outgoing_deny(subnet), ipv4_internal_nat_rule],
      [
        icc_allow(network, "inet6"),
        outgoing_deny(subnet6),
        ipv6_internal_nat_rule
      ]
    )
  end

  defp network_filtering(%Schemas.Network{internal: true, icc: true, nat: _nat_if} = network) do
    {subnet, subnet6, _interface, nat_interface, host_gateway_interface} =
      defined_network_macros(network.id)

    ipv4_internal_nat_rule = "block out quick log on #{nat_interface} from #{subnet}"
    ipv6_internal_nat_rule = "block out quick log on #{host_gateway_interface} from #{subnet6}"

    use_necessary_ip_protocols(
      network,
      [icc_allow(network, "inet"), outgoing_deny(subnet), ipv4_internal_nat_rule],
      [
        icc_allow(network, "inet6"),
        outgoing_deny(subnet6),
        ipv6_internal_nat_rule
      ]
    )
  end

  defp network_filtering(%Schemas.Network{internal: true, icc: false, nat: ""} = network) do
    {subnet, subnet6, _interface, _nat_interface, _host_gateway_interface} =
      defined_network_macros(network.id)

    use_necessary_ip_protocols(network, [outgoing_deny(subnet)], [
      outgoing_deny(subnet6)
    ])
  end

  defp network_filtering(%Schemas.Network{internal: true, icc: false, nat: _nat_if} = network) do
    {subnet, subnet6, _interface, nat_interface, host_gateway_interface} =
      defined_network_macros(network.id)

    ipv4_internal_nat_rule = "block out quick log on #{nat_interface} from #{subnet}"
    ipv6_internal_nat_rule = "block out quick log on #{host_gateway_interface} from #{subnet6}"

    use_necessary_ip_protocols(network, [outgoing_deny(subnet), ipv4_internal_nat_rule], [
      outgoing_deny(subnet6),
      ipv6_internal_nat_rule
    ])
  end

  defp outgoing_deny(subnet) do
    "block out quick log on $kleenet_network_interfaces from #{subnet}"
  end

  defp icc_allow(network, proto) do
    {subnet, subnet6, _interface, _nat_interface, _host_gateway_interface} =
      defined_network_macros(network.id)

    prefix = prefix(network.id)

    case proto do
      "inet" -> "pass quick on $#{prefix}_all_interfaces from #{subnet} to #{subnet}"
      "inet6" -> "pass quick on $#{prefix}_all_interfaces from #{subnet6} to #{subnet6}"
    end
  end

  defp defined_network_macros(network_id) do
    prefix = prefix(network_id)
    subnet = "$#{prefix}_subnet"
    subnet6 = "$#{prefix}_subnet6"
    interface = "$#{prefix}_interface"
    nat_interface = "$#{prefix}_nat_if"
    host_gateway_interface = "$kleenet_host_gw_if"
    {subnet, subnet6, interface, nat_interface, host_gateway_interface}
  end

  defp use_necessary_ip_protocols(
         %Schemas.PublishedPort{ip_address: ip4, ip_address6: ip6},
         ip4_rules,
         ip6_rules
       ) do
    # Apply rules to IPv4 and/or IPv6 depending on what is defined for the network
    case {ip4, ip6} do
      {"", ""} -> []
      {_ip4, ""} -> ip4_rules
      {"", _ip6} -> ip6_rules
      {_ip, _ip6} -> List.flatten([ip4_rules, ip6_rules])
    end
  end

  defp use_necessary_ip_protocols(
         %Schemas.Network{subnet: subnet, subnet6: subnet6},
         ip4_rules,
         ip6_rules
       ) do
    # Apply rules to IPv4 and/or IPv6 depending on what is defined for the network
    case {subnet, subnet6} do
      {"", ""} -> []
      {_subnet, ""} -> ip4_rules
      {"", _subnet6} -> ip6_rules
      {_subnet, _subnet6} -> List.flatten([ip4_rules, ip6_rules])
    end
  end

  defp network_translation(network) do
    prefix = prefix(network.id)

    nat_rule = [
      "nat on $#{prefix}_nat_if from ($#{prefix}_interface:network) to any -> ($#{prefix}_nat_if)"
    ]

    case network do
      %Schemas.Network{nat: ""} -> []
      %Schemas.Network{internal: true} -> []
      _ -> nat_rule
    end
  end

  defp network_macros(network) do
    prefix = prefix(network.id)

    # Only set macros for stuff that is defined on the network
    basic_macros =
      [
        interface: network.interface,
        subnet: network.subnet,
        subnet6: network.subnet6,
        nat_if: network.nat
      ]
      |> Enum.filter(fn {_, value} -> value != "" end)
      |> Enum.map(fn {type, value} -> "#{prefix}_#{type}=\"#{value}\"" end)

    basic_macros ++ [all_network_interfaces(network)]
  end

  defp all_network_interfaces(network) do
    prefix = prefix(network.id)

    epairs =
      MetaData.get_endpoints_from_network(network.id)
      |> Enum.filter(&(&1.epair != nil and &1.epair != ""))
      |> Enum.map(&"#{&1.epair}a")

    all_interfaces = Enum.join([network.interface | epairs], ", ")

    "#{prefix}_all_interfaces=\"{#{all_interfaces}}\""
  end

  defp network_interfaces_macro(networks) do
    case length(networks) do
      0 ->
        []

      _ ->
        interfaces = Enum.map(networks, & &1.interface)
        ["kleenet_network_interfaces=\"{#{Enum.join(interfaces, ",")}}\""]
    end
  end

  defp host_gw_macro() do
    case host_gateway_interface() do
      {:ok, host_gw} ->
        ["kleenet_host_gw_if=\"#{host_gw}\""]

      {:error, _} ->
        Logger.warn(
          "Could not detect any gateway interface on the host. Connectivity might not work."
        )

        []
    end
  end

  def enable_pf() do
    OS.cmd(~w"/sbin/pfctl -e", %{suppress_warning: true})
  end

  def load_pf_config(config) do
    # For debugging purposes:
    # Logger.debug("PF Config:\n#{config}")
    pf_config_path = Config.get("pf_config_path")

    case File.write(pf_config_path, config, [:write]) do
      :ok ->
        case OS.cmd(~w"/sbin/pfctl -f #{pf_config_path}") do
          {_, 0} ->
            :ok

          {"", 1} ->
            Logger.error("Failed to load PF configuration file.")

          {error_output, 1} ->
            Logger.error("Failed to load PF configuration file: #{inspect(error_output)}")
        end

      {:error, reason} ->
        Logger.error("Failed to write PF configuration file with reason: #{inspect(reason)} ")
    end
  end

  defp generate_interface_name() do
    existing_interfaces =
      MetaData.list_networks()
      |> Enum.map(fn
        %Schemas.Network{interface: interface} -> interface
      end)
      |> MapSet.new()

    find_new_interface_name(existing_interfaces, 0)
  end

  defp find_new_interface_name(existing_interfaces, counter) do
    interface = "kleene#{counter}"

    case MapSet.member?(existing_interfaces, interface) do
      true -> find_new_interface_name(existing_interfaces, counter + 1)
      false -> interface
    end
  end

  def destroy_interface(kleene_if) do
    if interface_exists(kleene_if) do
      {"", _exitcode} = System.cmd("ifconfig", [kleene_if, "destroy"])
    end
  end

  def interface_exists(kleene_if) do
    {json, 0} = System.cmd("netstat", ["--libxo", "json", "-I", kleene_if])

    case Jason.decode(json) do
      {:ok, %{"statistics" => %{"interface" => []}}} -> false
      {:ok, %{"statistics" => %{"interface" => _if_stats}}} -> true
    end
  end

  def host_gateway_interface() do
    case get_routing_table(:ipv4) do
      {:ok, routing_table} ->
        case Enum.find(routing_table, "", fn %{"destination" => dest} -> dest == "default" end) do
          # Extract the interface name of the default gateway
          %{"interface-name" => interface} -> {:ok, interface}
          _ -> {:error, "Could not find a default gateway."}
        end

      _ ->
        {:error, "could not find routing table"}
    end
  end

  def get_routing_table(protocol) do
    address_family =
      case protocol do
        :ipv4 -> "Internet"
        :ipv6 -> "Internet6"
      end

    {output_json, 0} = OS.cmd(["netstat", "--libxo", "json", "-rn"])
    {:ok, output} = Jason.decode(output_json)
    routing_table = output["statistics"]["route-information"]["route-table"]["rt-family"]

    case Enum.filter(
           routing_table,
           fn
             %{"address-family" => ^address_family} -> true
             %{"address-family" => _} -> false
           end
         ) do
      [%{"rt-entry" => routes}] ->
        {:ok, routes}

      _ ->
        {:error, "could not find an #{address_family} routing table"}
    end
  end

  defp validate_ip("<auto>", :gateway6) do
    :ok
  end

  defp validate_ip("<auto>", :gateway) do
    :ok
  end

  defp validate_ip("", _type) do
    :ok
  end

  defp validate_ip(ip, type) do
    case CIDR.parse(ip) do
      %CIDR{} = cidr ->
        case {type, tuple_size(cidr.first)} do
          {:gateway6, 8} -> :ok
          {:subnet6, 8} -> :ok
          {:subnet, 4} -> :ok
          {:gateway, 4} -> :ok
          _ -> {:error, "wrong IP protocol"}
        end

      {:error, reason} ->
        {:error, reason}
    end
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
    #  "jail-information": {"jail": [{"jid":83,"hostname":"","path":"/zroot/kleene_basejail","name":"83","state":"ACTIVE","cpusetid":4, "ipv4_addrs": ["172.17.0.1","172.17.0.2"], "ipv6_addrs": []}]}
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

  defp ifconfig_cidr_alias("", _subnet, _interface, _protocol) do
    :ok
  end

  defp ifconfig_cidr_alias(ip, subnet, interface, protocol) do
    %CIDR{mask: mask} = CIDR.parse(subnet)
    ifconfig_alias_add("#{ip}/#{mask}", interface, protocol)
  end

  defp ifconfig_alias_add("", _interface, _proto) do
    :ok
  end

  defp ifconfig_alias_add(ip, interface, protocol) do
    Logger.debug("Adding #{protocol} #{ip} to #{interface}")

    case OS.cmd(~w"ifconfig #{interface} #{protocol} #{ip} alias") do
      {_output, 0} ->
        :ok

      {output, _nonzero_exitcode} ->
        {:error, "error adding #{protocol} alias to interface: #{output}"}
    end
  end

  defp ifconfig_alias_remove("", _interface, _protocol) do
    :ok
  end

  defp ifconfig_alias_remove(ip, interface, protocol) do
    Logger.debug("Removing #{protocol} #{ip} from #{interface}")

    case OS.cmd(~w"ifconfig #{interface} #{protocol} #{ip} -alias") do
      {_, 0} ->
        :ok

      {output, _nonzero_exit} ->
        {:error, "error adding #{protocol} alias to interface: #{output}"}
    end
  end

  defp new_ip(%Schemas.Network{interface: interface, id: network_id} = network, protocol) do
    subnet =
      case protocol do
        "inet" -> network.subnet
        "inet6" -> network.subnet6
      end

    ips_in_use = ips_on_interface(interface, protocol) ++ ips_from_endpoints(network_id, protocol)

    %CIDR{:last => last_ip} = CIDR.parse(subnet)
    first_ip = first_ip_address(subnet, protocol)
    generate_ip(first_ip, last_ip, ips_in_use, protocol)
  end

  defp first_ip_address(subnet, protocol) do
    %CIDR{:first => first_ip} = CIDR.parse(subnet)
    first_ip |> ip2int(protocol) |> (&(&1 + 1)).() |> int2ip(protocol)
  end

  def ips_from_endpoints(network_id, protocol) do
    configs = MetaData.get_endpoints_from_network(network_id)

    raw_ip_list =
      case protocol do
        "inet" -> Enum.map(configs, & &1.ip_address)
        "inet6" -> Enum.map(configs, & &1.ip_address6)
      end

    raw_ip_list |> Enum.filter(&(&1 != nil and &1 != ""))
  end

  defp ips_on_interface(interface, protocol) do
    {output_json, 0} = System.cmd("netstat", ["--libxo", "json", "-I", interface])
    %{"statistics" => %{"interface" => addresses}} = Jason.decode!(output_json)
    extract_ips(addresses, protocol)
  end

  defp extract_ips(addresses, protocol) do
    ip_len =
      case protocol do
        "inet" -> 4
        "inet6" -> 8
      end

    addresses
    |> Enum.filter(fn %{"address" => address} ->
      case CIDR.parse(address) do
        %CIDR{first: ip} when tuple_size(ip) == ip_len -> true
        _ -> false
      end
    end)
    |> Enum.map(& &1["address"])
  end

  defp generate_ip(first_ip, last_ip, ips_in_use, protocol) do
    first_ip = ip2int(first_ip, protocol)
    last_ip = ip2int(last_ip, protocol)
    ips_in_use = MapSet.new(Enum.map(ips_in_use, &ip2int(&1, protocol)))
    next_ip = first_ip

    case next_unused_int_ip(first_ip, last_ip, next_ip, ips_in_use) do
      :out_of_ips ->
        :out_of_ips

      ip_int ->
        int2ip(ip_int, protocol)
    end
  end

  defp next_unused_int_ip(_first_ip, last_ip, next_ip, _ips_in_use) when next_ip > last_ip do
    :out_of_ips
  end

  defp next_unused_int_ip(first_ip, last_ip, next_ip, ips_in_use) do
    case MapSet.member?(ips_in_use, next_ip) do
      true ->
        next_unused_int_ip(first_ip, last_ip, next_ip + 1, ips_in_use)

      false ->
        next_ip
    end
  end

  defp int2ip(n, "inet") do
    int2ip_(n, 3, [], "inet")
  end

  defp int2ip(n, "inet6") do
    int2ip_(n, 7, [], "inet6")
  end

  defp int2ip_(n, 0, prev, _protocol) do
    [n | prev]
    |> Enum.reverse()
    |> List.to_tuple()
    |> :inet.ntoa()
    |> to_string()
  end

  defp int2ip_(n, order, prev, "inet") do
    x = floor(n / pow_ipv4(order))
    n_next = n - x * pow_ipv4(order)
    int2ip_(n_next, order - 1, [x | prev], "inet")
  end

  defp int2ip_(n, order, prev, "inet6") do
    x = floor(n / pow_ipv6(order))
    n_next = n - x * pow_ipv6(order)
    int2ip_(n_next, order - 1, [x | prev], "inet6")
  end

  defp ip2int({a, b, c, d}, "inet") do
    d + c * pow_ipv4(1) + b * pow_ipv4(2) + a * pow_ipv4(3)
  end

  defp ip2int(ip, "inet") do
    {:ok, {a, b, c, d}} = ip |> to_charlist() |> :inet.parse_address()
    ip2int({a, b, c, d}, "inet")
  end

  defp ip2int({a, b, c, d, e, f, g, h}, "inet6") do
    h + g * pow_ipv6(1) + f * pow_ipv6(2) + e * pow_ipv6(3) + d * pow_ipv6(4) + c * pow_ipv6(5) +
      b * pow_ipv6(6) + a * pow_ipv6(7)
  end

  defp ip2int(ip, "inet6") do
    {:ok, {a, b, c, d, e, f, g, h}} = ip |> to_charlist() |> :inet.parse_address()
    ip2int({a, b, c, d, e, f, g, h}, "inet6")
  end

  defp pow_ipv6(n) do
    :erlang.round(:math.pow(65536, n))
  end

  defp pow_ipv4(n) do
    :erlang.round(:math.pow(256, n))
  end
end
