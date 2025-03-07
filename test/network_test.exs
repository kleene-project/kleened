defmodule NetworkTest do
  use Kleened.Test.ConnCase
  alias ExUnit.CaptureLog
  require Logger
  alias Kleened.Core.{Network, MetaData, OS}
  alias Kleened.Core.Utils.CIDR
  alias Kleened.API.Schemas

  @moduletag :capture_log

  @cant_connect_vnet_with_loopback %{
    message: "containers using the 'vnet' network-driver can't connect to loopback networks"
  }

  @cant_connect_vnet_with_custom %{
    message: "containers using the 'vnet' network-driver can't connect to custom networks"
  }

  @cant_connect_host_with_any %{
    message: "containers with the 'host' network-driver cannot connect to networks."
  }
  @cant_connect_disabled_with_any %{
    message: "containers with the 'disabled' network-driver cannot connect to networks."
  }
  setup do
    TestHelper.cleanup()

    on_exit(fn ->
      CaptureLog.capture_log(fn ->
        TestHelper.cleanup()
      end)
    end)

    :ok
  end

  test "create, inspect, connect, and remove a 'loopback' network with custom interface name", %{
    api_spec: api_spec
  } do
    interface = "testnet"
    Network.destroy_interface(interface)

    %Schemas.Network{id: network_id} =
      network =
      create_network(%{
        name: "loopback_net",
        interface: interface,
        subnet: "172.19.1.0/24",
        type: "loopback"
      })

    # Verify that ipnet containers can connect to loopback networks
    {container_id, _, addresses} =
      netstat_in_container(%{network_driver: "ipnet", network: network.name})

    assert [%{"address" => "172.19.1.1", "network" => "172.19.1.1/32"}] =
             filter_by_interface(addresses, interface)

    # Inspect container
    assert %{
             container: %Schemas.Container{network_driver: "ipnet"},
             container_endpoints: [
               %Schemas.EndPoint{
                 epair: nil,
                 ip_address: "172.19.1.1",
                 network_id: ^network_id,
                 ip_address6: ""
               }
             ]
           } = TestHelper.container_inspect(container_id)

    assert :ok == TestHelper.network_disconnect(api_spec, network.name, container_id)

    # Verifying that vnet containers can't connect to loopback networks
    output = failing_to_connect_container(["loopback_net"], "vnet")
    assert output == [@cant_connect_vnet_with_loopback]

    # Cleanup
    assert TestHelper.network_remove(api_spec, network.name) == %{id: network.id}
    assert not Network.interface_exists(interface)
    assert MetaData.get_network(network.id) == :not_found
  end

  test "create, inspect, connect, and remove a 'bridge' network with auto-generated interface name",
       %{
         api_spec: api_spec
       } do
    interface = "kleene0"
    Network.destroy_interface(interface)

    %Schemas.Network{id: network_id} =
      network =
      create_network(%{
        name: "bridge_net",
        subnet: "172.19.2.0/24",
        gateway: "",
        type: "bridge"
      })

    # Verify that ipnet containers can connect to bridge networks
    {container_id_ipnet, _, addresses} =
      netstat_in_container(%{network: network.name, network_driver: "ipnet"})

    assert [%{"address" => "172.19.2.1", "network" => "172.19.2.1/32"}] =
             filter_by_interface(addresses, interface)

    # Inspect container
    assert %{
             container: %Schemas.Container{network_driver: "ipnet"},
             container_endpoints: [
               %Schemas.EndPoint{
                 epair: nil,
                 ip_address: "172.19.2.1",
                 ip_address6: "",
                 network_id: ^network_id
               }
             ]
           } = TestHelper.container_inspect(container_id_ipnet)

    # Verifying that vnet containers can connect to bridge networks
    {container_id_vnet, _, addresses} =
      netstat_in_container(%{network: network.name, network_driver: "vnet"})

    assert [%{"address" => "172.19.2.2", "network" => "172.19.2.0/24"}] =
             filter_by_interface(addresses, "epair0b")

    # Inspect container
    assert %{
             container: %Schemas.Container{network_driver: "vnet"},
             container_endpoints: [
               %Schemas.EndPoint{
                 # Because the container is not running there is no 'epair' allocated.
                 epair: nil,
                 ip_address: "172.19.2.2",
                 ip_address6: "",
                 network_id: ^network_id
               }
             ]
           } = TestHelper.container_inspect(container_id_vnet)

    assert :ok == TestHelper.network_disconnect(api_spec, network.name, container_id_vnet)
    assert :ok == TestHelper.network_disconnect(api_spec, network.name, container_id_ipnet)

    # Cleanup
    assert TestHelper.network_remove(api_spec, network.name) == %{id: network.id}
    assert not Network.interface_exists("kleene0")
    assert MetaData.get_network(network.id) == :not_found
  end

  test "create, inspect, connect and remove a 'custom' network", %{
    api_spec: api_spec
  } do
    interface = "custom_if"
    Network.destroy_interface(interface)
    Network.create_interface("lo", interface)

    %Schemas.Network{id: network_id} =
      network =
      create_network(%{
        name: "custom_net",
        subnet: "172.19.3.0/24",
        interface: interface,
        gateway: "",
        type: "custom"
      })

    # Verify that ipnet containers can connect to bridge networks
    {container_id, _, addresses} =
      netstat_in_container(%{network: network.name, network_driver: "ipnet"})

    assert [%{"address" => "172.19.3.1", "network" => "172.19.3.1/32"}] =
             filter_by_interface(addresses, interface)

    # Inspect container
    assert %{
             container: %Schemas.Container{network_driver: "ipnet"},
             container_endpoints: [
               %Schemas.EndPoint{
                 epair: nil,
                 ip_address: "172.19.3.1",
                 ip_address6: "",
                 network_id: ^network_id
               }
             ]
           } = TestHelper.container_inspect(container_id)

    # Verifying that vnet containers can't connect to custom networks
    output = failing_to_connect_container(["custom_net"], "vnet")
    assert output == [@cant_connect_vnet_with_custom]
    assert :ok == TestHelper.network_disconnect(api_spec, network.name, container_id)

    # Cleanup
    assert TestHelper.network_remove(api_spec, network.name) == %{id: network.id}
    assert Network.interface_exists("custom_if")
    assert MetaData.get_network(network.id) == :not_found
    Network.destroy_interface(interface)
  end

  test "listing networks", %{api_spec: api_spec} do
    Network.destroy_interface("kleene1")

    assert [] = TestHelper.network_list(api_spec)

    network1 = create_network(%{name: "testnet1", type: "bridge"})
    create_network(%{name: "testnet2", type: "bridge"})

    assert [
             %{name: "testnet1"},
             %{name: "testnet2"}
           ] = TestHelper.network_list(api_spec)

    assert TestHelper.network_remove(api_spec, network1.name) == %{id: network1.id}

    assert [
             %{name: "testnet2"}
           ] = TestHelper.network_list(api_spec)
  end

  test "prune networks", %{api_spec: api_spec} do
    network1 = create_network(%{name: "testnet1", type: "loopback"})

    %Schemas.Network{id: network2_id} = create_network(%{name: "testnet2", type: "bridge"})

    %{id: container_id} =
      TestHelper.container_create(%{
        name: "network_prune_test",
        cmd: ["/bin/sleep", "10"],
        network_driver: "ipnet",
        network: "testnet1"
      })

    assert [network2_id] == TestHelper.network_prune(api_spec)
    assert [%{name: "testnet1"}] = TestHelper.network_list(api_spec)
    assert :ok == TestHelper.network_disconnect(api_spec, network1.id, container_id)
  end

  test "inspecting a network that doesn't exist" do
    %Schemas.Network{} = create_network(%{type: "loopback"})
    response = TestHelper.network_inspect_raw("notexist")
    assert response.status == 404
    assert response.resp_body == "{\"message\":\"network not found\"}"
  end

  test "remove a non-existing network", %{api_spec: api_spec} do
    network = create_network(%{ifname: "kleene1", driver: "loopback"})
    assert TestHelper.network_remove(api_spec, network.name) == %{id: network.id}
    assert TestHelper.network_remove(api_spec, network.name) == %{message: "network not found."}
  end

  test "create a network with same name twice", %{api_spec: api_spec} do
    network = create_network(%{type: "loopback"})

    assert %{message: "network name is already taken"} ==
             TestHelper.network_create(%{
               name: "testnet",
               subnet: "172.19.0.0/16",
               type: "loopback"
             })

    assert TestHelper.network_remove(api_spec, network.name) == %{id: network.id}
  end

  test "try to create a network with an invalid subnet" do
    assert %{message: "invalid subnet: could not parse cidr block: \"172.18.0.0-16\""} =
             TestHelper.network_create(%{
               # Only CIDR-notation allowed
               name: "testnet",
               subnet: "172.18.0.0-16",
               type: "bridge"
             })
  end

  test "cannot set ip-adresses when there is no corresponding subnet defined on the network" do
    interface = "testnet"
    Network.destroy_interface(interface)

    network =
      create_network(%{
        name: "loopback_net",
        interface: interface,
        subnet: "",
        subnet6: "",
        type: "loopback"
      })

    %{message: "cannot set ip address because there is no IPv4 subnet defined for this network"} =
      TestHelper.container_create(%{
        name: "testnetwork1",
        network_driver: "ipnet",
        network: network.name,
        ip_address: "10.56.78.2",
        ip_address6: ""
      })

    %{message: "cannot set ip address because there is no IPv6 subnet defined for this network"} =
      TestHelper.container_create(%{
        name: "testnetwork2",
        network_driver: "ipnet",
        network: network.name,
        ip_address: "",
        ip_address6: "fdef:1234:5678::10"
      })
  end

  test "can't specify a IPv4 block in the 'subnet6'/'gateway6' field and vice versa" do
    config_default = %{
      subnet: "",
      subnet6: "",
      type: "loopback",
      gateway: "",
      gateway6: ""
    }

    assert %{message: "invalid subnet6: wrong IP protocol"} ==
             TestHelper.network_create(
               Map.merge(config_default, %{
                 name: "testnet1",
                 subnet6: "10.1.2.0/24"
               })
             )

    assert %{message: "invalid gateway6: wrong IP protocol"} ==
             TestHelper.network_create(
               Map.merge(config_default, %{
                 name: "testnet2",
                 subnet6: "beef:beef::1",
                 gateway6: "127.0.0.1"
               })
             )

    assert %{message: "invalid subnet: wrong IP protocol"} ==
             TestHelper.network_create(
               Map.merge(config_default, %{
                 name: "testnet3",
                 subnet: "beef:beef::/64"
               })
             )

    assert %{message: "invalid gateway: wrong IP protocol"} ==
             TestHelper.network_create(
               Map.merge(config_default, %{
                 name: "testnet4",
                 subnet: "10.1.2.0/24",
                 gateway: "beef:beef::1"
               })
             )
  end

  test "try to connect twice" do
    network = create_network(%{})

    %{id: container_id} =
      TestHelper.container_create(%{
        name: "network_test",
        cmd: ["/bin/sleep", "10"],
        network_driver: "ipnet",
        network: ""
      })

    assert :ok == TestHelper.network_connect(network.name, container_id)

    assert %{message: "container already connected to the network"} ==
             TestHelper.network_connect(network.name, container_id)
  end

  test "try to disconnect twice", %{api_spec: api_spec} do
    network = create_network(%{})

    %{id: container_id} =
      TestHelper.container_create(%{
        name: "network_test",
        cmd: ["/bin/sleep", "10"],
        network: network.name,
        network_driver: "ipnet"
      })

    assert :ok == TestHelper.network_disconnect(api_spec, network.id, container_id)

    assert %{message: "endpoint configuration not found"} ==
             TestHelper.network_disconnect(api_spec, network.id, container_id)
  end

  test "exhaust all ips in a network" do
    create_network(%{name: "smallnet", subnet: "172.19.0.0/30", type: "loopback"})

    config = %{cmd: ["/bin/ls"], network: "smallnet", network_driver: "ipnet"}

    %{id: _id} = TestHelper.container_create(Map.put(config, :name, "exhaust1"))
    %{id: _id} = TestHelper.container_create(Map.put(config, :name, "exhaust2"))
    %{id: _id} = TestHelper.container_create(Map.put(config, :name, "exhaust3"))

    assert %{message: "no more inet IP's left in the network"} =
             TestHelper.container_create(Map.put(config, :name, "exhaust4"))
  end

  test "create a container that uses the 'host' network driver" do
    ip_addresses_on_host = only_ip_addresses(host_addresses())

    {_container_id, _routing_info, addresses} = netstat_in_container(%{network_driver: "host"})

    ip_addresses_in_container = only_ip_addresses(trim_adresses(addresses))

    assert MapSet.new(ip_addresses_on_host) == MapSet.new(ip_addresses_in_container)
  end

  test "a container using the 'host' network driver can't connect to a loopback network" do
    network =
      create_network(%{
        name: "loopback_net",
        subnet: "172.19.1.0/24",
        type: "loopback"
      })

    assert [@cant_connect_host_with_any] ==
             failing_to_connect_container([network.name], "host")
  end

  test "a container using the 'host' network driver can't connect to a bridge network" do
    network =
      create_network(%{
        name: "bridge_net",
        subnet: "172.19.2.0/24",
        type: "bridge"
      })

    assert [@cant_connect_host_with_any] ==
             failing_to_connect_container([network.name], "host")
  end

  test "a container using the 'host' network driver can't connect to a custom network" do
    network =
      create_network(%{
        name: "custom_net",
        interface: "em0",
        subnet: "172.19.3.0/24",
        gateway: "",
        type: "custom",
        # NAT needs to be disabled when using 'em0' as the custom interface
        # since it is also the GW interface. Otherwise, it will NAT traffic on
        # 'em0' to itself which breaks connectivity to the vagrant box.
        nat: ""
      })

    assert [@cant_connect_host_with_any] ==
             failing_to_connect_container([network.name], "host")
  end

  test "create a container that uses the 'disabled' network driver" do
    {_container_id, routing_info, addresses} = netstat_in_container(%{network_driver: "disabled"})

    assert %{"route-table" => %{"rt-family" => []}} = routing_info
    assert [] == remove_link_addresses(addresses)
  end

  test "a container using the 'disabled' network driver can't connect to networks" do
    network =
      create_network(%{
        name: "loopback_net",
        subnet: "172.19.1.0/24",
        type: "loopback"
      })

    assert [@cant_connect_disabled_with_any] ==
             failing_to_connect_container([network.name], "disabled")

    network =
      create_network(%{
        name: "bridge_net",
        subnet: "172.19.2.0/24",
        type: "bridge"
      })

    assert failing_to_connect_container([network.name], "disabled") ==
             [@cant_connect_disabled_with_any]

    network =
      create_network(%{
        name: "custom_net",
        interface: "em0",
        subnet: "172.19.3.0/24",
        gateway: "",
        nat: "",
        type: "custom"
      })

    assert [@cant_connect_disabled_with_any] =
             failing_to_connect_container([network.name], "disabled")
  end

  test "Gateways of 'loopback' networks are not used" do
    Network.destroy_interface("kleene0")

    network =
      create_network(%{
        subnet: "172.19.1.0/24",
        subnet6: "fdef:1234:5678::/48",
        # Gateways should have no effect on a loopback network.
        gateway: "172.19.1.99",
        gateway6: "fdef:1234:5678:9999::",
        type: "loopback"
      })

    ## ipnet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{network: network.name, network_driver: "ipnet"})

    assert [%{"address" => "172.19.1.1", "network" => "172.19.1.1/32"}] =
             filter_by_interface(addresses, "kleene0")

    assert [%{"destination" => "172.19.1.1", "interface-name" => "kleene0"}] =
             routes(routing_info)
  end

  test "Gateways of 'custom' networks are not used" do
    interface = "custom0"
    Network.destroy_interface(interface)
    Network.create_interface("lo", interface)

    network =
      create_network(%{
        interface: interface,
        subnet: "172.19.1.0/24",
        subnet6: "fdef:1234:5678::/48",
        # Gateways should have no effect on a loopback network.
        gateway: "172.19.1.99",
        gateway6: "fdef:1234:5678:9999::",
        type: "custom"
      })

    ## ipnet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{network: network.name, network_driver: "ipnet"})

    assert [%{"address" => "172.19.1.1", "network" => "172.19.1.1/32"}] =
             filter_by_interface(addresses, interface)

    assert [%{"destination" => "172.19.1.1", "interface-name" => ^interface}] =
             routes(routing_info)

    Network.remove(network.id)
    Network.destroy_interface("kleene0")
    Network.destroy_interface(interface)
  end

  test "Manually set gateways for (IPv4 + 6) for 'vnet' containers on 'bridge' networks" do
    Network.destroy_interface("kleene0")

    network =
      create_network(%{
        name: "bridge_net",
        subnet: "172.19.1.0/24",
        subnet6: "fdef:1234:5678::/48",
        gateway: "172.19.1.99",
        gateway6: "fdef:1234:5678:9999::",
        type: "bridge"
      })

    ## ipnet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{
        network: network.name,
        network_driver: "ipnet",
        ip_address: "<auto>",
        ip_address6: "<auto>"
      })

    assert MapSet.new([
             %{address: "fdef:1234:5678::1", network: "fdef:1234:5678::1/128"},
             %{address: "172.19.1.1", network: "172.19.1.1/32"}
           ]) == filter_by_interface(addresses, "kleene0") |> address_mapset()

    # Unsure why it ends up being "lo0" and not "kleene0"
    assert [%{"destination" => "172.19.1.1", "interface-name" => "lo0"}] = routes(routing_info)

    assert [%{"destination" => "fdef:1234:5678::1", "interface-name" => "lo0"}] =
             routes6(routing_info)

    ## VNet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{
        network: network.name,
        network_driver: "vnet",
        ip_address: "<auto>",
        ip_address6: "<auto>"
      })

    assert [
             %{"address" => "172.19.1.2", "network" => "172.19.1.0/24"},
             %{"address" => "fdef:1234:5678::2", "network" => "fdef:1234:5678::/48"},
             %{"network" => "fe80::%epair0b/64"}
           ] = filter_by_interface(addresses, "epair0b")

    assert [
             %{
               "destination" => "default",
               "interface-name" => "epair0b",
               "gateway" => "172.19.1.99"
             },
             %{
               "destination" => "172.19.1.0/24",
               "gateway" => <<"link#", _::binary>>,
               "interface-name" => "epair0b"
             },
             %{
               "destination" => "172.19.1.2",
               "gateway" => <<"link#", _::binary>>,
               "interface-name" => "lo0"
             }
           ] = routes(routing_info)

    assert [
             %{
               "destination" => "default",
               "gateway" => "fdef:1234:5678:9999::",
               "interface-name" => "epair0b"
             },
             %{
               "destination" => "fdef:1234:5678::/48",
               "interface-name" => "epair0b"
             },
             %{
               "destination" => "fdef:1234:5678::2",
               "interface-name" => "lo0"
             },
             %{
               "destination" => "fe80::%epair0b/64",
               "interface-name" => "epair0b"
             },
             # IPv6 link-local ip, e.g.: "destination" => "fe80::55:f4ff:fe46:cd0b%epair0b"
             %{"flags_pretty" => ["up", "host", "static"], "interface-name" => "lo0"}
           ] = routes6(routing_info)
  end

  test "Automatically set gateways for (IPv4 + 6) 'bridge' networks" do
    Network.destroy_interface("kleene0")

    network =
      create_network(%{
        name: "bridge_net",
        subnet: "172.19.1.0/24",
        subnet6: "fdef:1234:5678::/48",
        gateway: "<auto>",
        gateway6: "<auto>",
        type: "bridge"
      })

    assert MapSet.new([
             %{address: "172.19.1.1", network: "172.19.1.0/24"},
             %{address: "fdef:1234:5678::1", network: "fdef:1234:5678::/48"}
           ]) == filter_by_interface(host_addresses(), "kleene0") |> address_mapset()

    ## ipnet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{
        network: network.name,
        network_driver: "ipnet",
        ip_address: "<auto>",
        ip_address6: "<auto>"
      })

    assert MapSet.new([
             %{address: "172.19.1.2", network: "172.19.1.2/32"},
             %{address: "fdef:1234:5678::2", network: "fdef:1234:5678::2/128"}
           ]) == filter_by_interface(addresses, "kleene0") |> address_mapset()

    assert MapSet.new([
             %{address: "172.19.1.1", network: "172.19.1.0/24"},
             %{address: "fdef:1234:5678::1", network: "fdef:1234:5678::/48"}
           ]) == filter_by_interface(host_addresses(), "kleene0") |> address_mapset()

    assert [%{"destination" => "172.19.1.2", "interface-name" => "lo0"}] = routes(routing_info)

    assert [%{"destination" => "fdef:1234:5678::2", "interface-name" => "lo0"}] =
             routes6(routing_info)

    ## VNet
    {_container_id, routing_info, addresses} =
      netstat_in_container(%{
        network: network.name,
        network_driver: "vnet",
        ip_address: "<auto>",
        ip_address6: "<auto>"
      })

    assert [
             %{"address" => "172.19.1.3", "network" => "172.19.1.0/24"},
             %{"address" => "fdef:1234:5678::3", "network" => "fdef:1234:5678::/48"},
             %{"network" => "fe80::%epair0b/64"}
           ] = filter_by_interface(addresses, "epair0b")

    assert [
             %{
               "destination" => "default",
               "interface-name" => "epair0b",
               "gateway" => "172.19.1.1"
             },
             %{
               "destination" => "172.19.1.0/24",
               "gateway" => <<"link#", _::binary>>,
               "interface-name" => "epair0b"
             },
             %{
               "destination" => "172.19.1.3",
               "gateway" => <<"link#", _::binary>>,
               "interface-name" => "lo0"
             }
           ] = routes(routing_info)

    assert [
             %{
               "destination" => "default",
               "gateway" => "fdef:1234:5678::1",
               "interface-name" => "epair0b"
             },
             %{
               "destination" => "fdef:1234:5678::/48",
               "interface-name" => "epair0b"
             },
             %{
               "destination" => "fdef:1234:5678::3",
               "interface-name" => "lo0"
             },
             %{
               "destination" => "fe80::%epair0b/64",
               "interface-name" => "epair0b"
             },
             # IPv6 link-local ip:
             %{"flags_pretty" => ["up", "host", "static"], "interface-name" => "lo0"}
           ] = routes6(routing_info)
  end

  test "NAT'd connectivity of 'ipnet' containers" do
    # loopback IPv4
    container_connectivity_test(%{
      network: %{
        name: "testnet1",
        gateway: "",
        subnet: "10.13.37.0/24",
        nat: "<host-gateway>",
        type: "loopback"
      },
      client: %{network_driver: "ipnet"}
    })

    # bridge IPv4
    container_connectivity_test(%{
      network: %{
        name: "testnet2",
        gateway: "",
        subnet: "10.13.38.0/24",
        nat: "<host-gateway>",
        type: "bridge"
      },
      client: %{network_driver: "ipnet"}
    })
  end

  test "NAT'd connectivity of 'vnet' containers" do
    interface = "kleened0"
    Network.destroy_interface(interface)

    # bridge IPv4
    container_connectivity_test(%{
      network: %{
        name: "testnet2",
        gateway: "<auto>",
        subnet: "10.13.38.0/24",
        nat: "<host-gateway>",
        type: "bridge"
      },
      client: %{network_driver: "vnet"}
    })
  end

  test "No NAT means no connectivity on rfc1819 networks" do
    interface = "kleened0"
    Network.destroy_interface(interface)

    container_connectivity_test(%{
      network: %{
        name: "testnet1",
        gateway: "",
        subnet: "10.13.37.0/24",
        type: "loopback",
        nat: "",
        expected_exit_code: 1
      },
      client: %{network_driver: "ipnet"}
    })

    container_connectivity_test(%{
      network: %{
        name: "testnet2",
        # This is needed for bridge networks to get the host_interface:
        gateway: "<auto>",
        subnet: "10.13.38.0/24",
        type: "bridge",
        nat: "",
        expected_exit_code: 1
      },
      client: %{network_driver: "vnet"}
    })
  end

  test "no upstream connectivity on networks with no NAT and internal=true" do
    container_connectivity_test(%{
      network: %{
        name: "testnet1",
        gateway: "",
        subnet: "10.13.37.0/24",
        type: "loopback",
        nat: "",
        internal: true,
        expected_exit_code: 1
      },
      client: %{network_driver: "ipnet"},
      expect_fw_block: true
    })

    container_connectivity_test(%{
      network: %{
        name: "testnet2",
        # This is needed for bridge networks to get the host_interface:
        gateway: "<auto>",
        subnet: "10.13.38.0/24",
        type: "bridge",
        nat: "",
        internal: true,
        expected_exit_code: 1
      },
      client: %{network_driver: "vnet"},
      expect_fw_block: true
    })
  end

  test "no upstream connectivity on networks with auto-NAT and internal=true" do
    container_connectivity_test(%{
      network: %{
        name: "testnet1",
        gateway: "",
        subnet: "10.13.37.0/24",
        type: "loopback",
        nat: "<host-gateway>",
        internal: true,
        expected_exit_code: 1
      },
      client: %{network_driver: "ipnet"},
      expect_fw_block: true
    })

    container_connectivity_test(%{
      network: %{
        name: "testnet2",
        # This is needed for bridge networks to get the host_interface:
        gateway: "<auto>",
        subnet: "10.13.38.0/24",
        type: "bridge",
        nat: "<host-gateway>",
        internal: true,
        expected_exit_code: 1
      },
      # ,
      client: %{network_driver: "vnet"},
      expect_fw_block: true
    })
  end

  test "'ipnet' containers can communicate with each other over all networks using IPv4" do
    interface = "kleened0"
    Network.destroy_interface(interface)

    # Loopback
    inter_container_connectivity_test(%{
      network: %{
        name: "testnet1",
        subnet: "172.18.1.0/24",
        type: "loopback"
      },
      server: %{network_driver: "ipnet"},
      client: %{network_driver: "ipnet"},
      protocol: "inet"
    })

    # Bridge

    inter_container_connectivity_test(%{
      network: %{
        name: "testnet2",
        subnet: "172.19.1.0/24",
        type: "bridge"
      },
      server: %{network_driver: "ipnet"},
      client: %{network_driver: "ipnet"},
      protocol: "inet"
    })

    # Custom
    inter_container_connectivity_test(%{
      network: %{
        name: "testnet3",
        subnet: "172.20.1.0/24",
        interface: "em0",
        nat: "",
        type: "custom"
      },
      server: %{network_driver: "ipnet"},
      client: %{network_driver: "ipnet"},
      protocol: "inet"
    })
  end

  test "'ipnet' containers can communicate with each other over all networks using IPv6" do
    interface = "kleened0"
    Network.destroy_interface(interface)

    # Loopback
    inter_container_connectivity_test(%{
      network: %{
        name: "testnet1",
        subnet: "",
        subnet6: "fdef:1111:5678::/64",
        type: "loopback"
      },
      server: %{ip_address: "", ip_address6: "<auto>", network_driver: "ipnet"},
      client: %{ip_address: "", ip_address6: "<auto>", network_driver: "ipnet"},
      protocol: "inet6"
    })

    # Bridge (using IPv6)
    inter_container_connectivity_test(%{
      network: %{
        name: "testnet2",
        gateway: "",
        gateway6: "",
        subnet: "",
        subnet6: "fdef:2222:5678::/64",
        type: "bridge"
      },
      server: %{ip_address: "", ip_address6: "<auto>", network_driver: "ipnet"},
      client: %{ip_address: "", ip_address6: "<auto>", network_driver: "ipnet"},
      protocol: "inet6"
    })

    ## Custom
    inter_container_connectivity_test(%{
      network: %{
        name: "testnet3",
        subnet: "",
        subnet6: "fdef:3333:5678::/64",
        interface: "lo0",
        type: "custom"
      },
      server: %{ip_address: "", ip_address6: "<auto>", network_driver: "ipnet"},
      client: %{ip_address: "", ip_address6: "<auto>", network_driver: "ipnet"},
      protocol: "inet6"
    })
  end

  test "'vnet' containers can communicate over a 'bridge' network" do
    # bridge IPv4
    inter_container_connectivity_test(%{
      network: %{
        name: "testnet1",
        gateway: "<auto>",
        gateway6: "",
        subnet: "10.13.0.0/16",
        subnet6: "",
        type: "bridge"
      },
      server: %{ip_address: "<auto>", ip_address6: "", network_driver: "vnet"},
      client: %{ip_address: "<auto>", ip_address6: "", network_driver: "vnet"},
      protocol: "inet"
    })

    # Bridge (using IPv6)
    inter_container_connectivity_test(%{
      network: %{
        name: "testnet2",
        gateway: "",
        gateway6: "<auto>",
        subnet: "",
        subnet6: "fdef:2222:5678::/64",
        type: "bridge"
      },
      server: %{ip_address: "", ip_address6: "<auto>", network_driver: "vnet"},
      client: %{ip_address: "", ip_address6: "<auto>", network_driver: "vnet"},
      protocol: "inet6"
    })
  end

  test "ipnet containers on different networks can't communicate with eachother" do
    # bridge IPv4
    inter_container_connectivity_test(%{
      network_server: %{
        name: "testnet1",
        gateway: "",
        gateway6: "",
        subnet: "10.13.37.0/24",
        subnet6: "",
        type: "loopback"
      },
      network_client: %{
        name: "testnet2",
        gateway: "",
        gateway6: "",
        subnet: "10.13.38.0/24",
        subnet6: "",
        type: "loopback"
      },
      server: %{network_driver: "ipnet"},
      client: %{network_driver: "ipnet"},
      protocol: "inet",
      expected_result: :timeout
    })

    # Bridge (using IPv6)
    inter_container_connectivity_test(%{
      network_server: %{
        name: "testnet3",
        gateway: "",
        gateway6: "<auto>",
        subnet: "",
        subnet6: "fdef:3333:3333::/64",
        nat: "",
        type: "loopback"
      },
      network_client: %{
        name: "testnet4",
        gateway: "",
        gateway6: "<auto>",
        subnet: "",
        subnet6: "fdef:4444:4444::/64",
        nat: "",
        type: "loopback"
      },
      server: %{network_driver: "ipnet"},
      client: %{network_driver: "ipnet"},
      protocol: "inet6",
      expected_result: :timeout
    })
  end

  test "vnet containers on different networks can't communicate with eachother" do
    # IPv4
    inter_container_connectivity_test(%{
      network_server: %{
        name: "testnet1",
        gateway: "<auto>",
        gateway6: "",
        subnet: "10.13.37.0/24",
        subnet6: "",
        type: "bridge"
      },
      network_client: %{
        name: "testnet2",
        gateway: "<auto>",
        gateway6: "",
        subnet: "10.13.38.0/24",
        subnet6: "",
        type: "bridge"
      },
      server: %{network_driver: "vnet"},
      client: %{network_driver: "vnet"},
      protocol: "inet",
      expected_result: :timeout
    })

    # using IPv6 and bridge
    inter_container_connectivity_test(%{
      network_server: %{
        name: "testnet3",
        gateway: "",
        gateway6: "<auto>",
        subnet: "",
        subnet6: "fdef:3333:3333::/64",
        nat: "",
        type: "bridge"
      },
      network_client: %{
        name: "testnet4",
        gateway: "",
        gateway6: "<auto>",
        subnet: "",
        subnet6: "fdef:4444:4444::/64",
        nat: "",
        type: "bridge"
      },
      server: %{network_driver: "vnet"},
      client: %{network_driver: "vnet"},
      protocol: "inet6",
      expected_result: :timeout
    })
  end

  test "ipnet and vnet containers on different networks can't communicate with eachother" do
    # IPv4
    inter_container_connectivity_test(%{
      network_server: %{
        name: "testnet1",
        gateway: "<auto>",
        gateway6: "",
        subnet: "10.13.37.0/24",
        subnet6: "",
        type: "bridge"
      },
      network_client: %{
        name: "testnet2",
        gateway: "<auto>",
        gateway6: "",
        subnet: "10.13.38.0/24",
        subnet6: "",
        type: "bridge"
      },
      server: %{network_driver: "ipnet"},
      client: %{network_driver: "vnet"},
      protocol: "inet",
      expected_result: :timeout
    })

    # using IPv6 and bridge
    inter_container_connectivity_test(%{
      network_server: %{
        name: "testnet3",
        gateway: "",
        gateway6: "<auto>",
        subnet: "",
        subnet6: "fdef:3333:3333::/64",
        nat: "",
        type: "bridge"
      },
      network_client: %{
        name: "testnet4",
        gateway: "",
        gateway6: "<auto>",
        subnet: "",
        subnet6: "fdef:4444:4444::/64",
        nat: "",
        type: "bridge"
      },
      server: %{network_driver: "ipnet"},
      client: %{network_driver: "vnet"},
      protocol: "inet6",
      expected_result: :timeout
    })
  end

  test "'vnet' and 'ipnet' containers can communicate over a 'bridge' network" do
    interface = "kleened0"
    Network.destroy_interface(interface)

    # bridge IPv4
    inter_container_connectivity_test(%{
      network: %{
        name: "testnet1",
        gateway: "<auto>",
        gateway6: "",
        subnet: "10.13.0.0/16",
        subnet6: "",
        type: "bridge"
      },
      server: %{ip_address: "<auto>", ip_address6: "", network_driver: "vnet"},
      client: %{ip_address: "<auto>", ip_address6: "", network_driver: "ipnet"},
      protocol: "inet"
    })

    # Bridge (using IPv6)
    inter_container_connectivity_test(%{
      network: %{
        name: "testnet2",
        gateway: "",
        gateway6: "<auto>",
        subnet: "",
        subnet6: "fdef:2222:5678::/64",
        type: "bridge"
      },
      server: %{ip_address: "", ip_address6: "<auto>", network_driver: "vnet"},
      client: %{ip_address: "", ip_address6: "<auto>", network_driver: "ipnet"},
      protocol: "inet6"
    })
  end

  test "'ipnet' containers cannot communicate with each other over networks with no icc" do
    interface = "kleened0"
    Network.destroy_interface(interface)

    # Loopback
    inter_container_connectivity_test(%{
      network: %{
        name: "testnet",
        subnet: "172.18.1.0/24",
        type: "loopback",
        icc: false
      },
      server: %{network_driver: "ipnet"},
      client: %{network_driver: "ipnet"},
      protocol: "inet",
      expected_result: :timeout
    })
  end

  test "'vnet' containers cannot communicate with each other over networks with icc=false" do
    interface = "kleened0"
    Network.destroy_interface(interface)

    inter_container_connectivity_test(%{
      network: %{
        name: "testnet",
        subnet6: "beef:beef::/64",
        gateway6: "<auto>",
        type: "bridge",
        icc: false
      },
      server: %{network_driver: "vnet"},
      client: %{network_driver: "vnet"},
      protocol: "inet6",
      expected_result: :timeout
    })
  end

  test "'vnet' and 'ipnet' containers cannot communicate with each other over networks with icc=false" do
    interface = "kleened0"
    Network.destroy_interface(interface)

    inter_container_connectivity_test(%{
      network: %{
        name: "testnet",
        subnet: "10.56.78.0/24",
        type: "bridge",
        icc: false
      },
      server: %{network_driver: "vnet"},
      client: %{network_driver: "ipnet"},
      protocol: "inet",
      expected_result: :timeout
    })
  end

  test "container using 'host' network driver can't publish ports" do
    %{message: "cannot publish ports of a container using the 'host' network driver"} =
      TestHelper.container_create(%{
        name: "test_public_port",
        network_driver: "host",
        public_ports: [%{interfaces: [], host_port: "4000", container_port: "4000"}]
      })
  end

  test "container using 'disabled' network driver can't publish ports" do
    %{message: "cannot publish ports of a container using the 'disabled' network driver"} =
      TestHelper.container_create(%{
        name: "test_public_port",
        network_driver: "disabled",
        public_ports: [%{interfaces: [], host_port: "4000", container_port: "4000"}]
      })
  end

  test "ipnet-containers publishing ports can be reached by ipnet containers in other networks using the local ip/port" do
    public_port_connectivity_test(%{
      network_server: %{
        name: "testnet0",
        subnet: "10.13.37.0/24",
        type: "loopback"
      },
      network_client: %{
        name: "testnet1",
        subnet: "10.13.38.0/24",
        type: "loopback"
      },
      server: %{
        network_driver: "ipnet",
        public_ports: [%{interfaces: [], host_port: "4000", container_port: "4000"}]
      },
      client: %{
        network_driver: "ipnet"
      },
      protocol: "inet"
    })

    public_port_connectivity_test(%{
      network_server: %{
        name: "testnet3",
        subnet6: "fdef:1337:1337::/64",
        type: "bridge"
      },
      network_client: %{
        name: "testnet4",
        subnet6: "fdef:1338:1338::/64",
        type: "bridge"
      },
      server: %{
        network_driver: "ipnet",
        public_ports: [%{interfaces: [], host_port: "4000", container_port: "4000"}]
      },
      client: %{
        network_driver: "ipnet"
      },
      protocol: "inet6"
    })
  end

  test "vnet-containers publishing ports can be reached by vnet containers in other networks using the local ip/port" do
    public_port_connectivity_test(%{
      network_server: %{
        name: "testnet0",
        subnet: "10.13.37.0/24",
        gateway: "<auto>",
        type: "bridge"
      },
      network_client: %{
        name: "testnet1",
        subnet: "10.13.38.0/24",
        gateway: "<auto>",
        type: "bridge"
      },
      server: %{
        network_driver: "vnet",
        public_ports: [%{interfaces: [], host_port: "4000", container_port: "4000"}]
      },
      client: %{
        network_driver: "vnet"
      },
      protocol: "inet"
    })
  end

  test "containers on icc: false networks can access a published port from a container in another network" do
    public_port_connectivity_test(%{
      network_server: %{
        name: "testnet0",
        subnet: "10.13.37.0/24",
        type: "loopback",
        icc: false
      },
      network_client: %{
        name: "testnet1",
        subnet: "10.13.38.0/24",
        type: "loopback",
        icc: false
      },
      server: %{
        network_driver: "ipnet",
        public_ports: [%{interfaces: [], host_port: "4000", container_port: "4000"}]
      },
      client: %{
        network_driver: "ipnet"
      },
      protocol: "inet"
    })
  end

  test "containers on icc: false networks can access a published port from a container in the same network" do
    public_port_connectivity_test(%{
      network: %{
        name: "testnet0",
        subnet: "10.13.37.0/24",
        type: "loopback",
        icc: false
      },
      server: %{
        network_driver: "ipnet",
        public_ports: [%{interfaces: [], host_port: "4000", container_port: "4000"}]
      },
      client: %{
        network_driver: "ipnet"
      },
      protocol: "inet"
    })
  end

  test "container on internal=true and icc=false networks cannot access a published port from another container" do
    public_port_connectivity_test(%{
      network_server: %{
        name: "testnet0",
        subnet: "10.13.37.0/24",
        type: "loopback"
      },
      network_client: %{
        name: "testnet1",
        subnet: "10.13.38.0/24",
        type: "loopback",
        internal: true,
        icc: false
      },
      server: %{
        network_driver: "ipnet",
        public_ports: [%{interfaces: [], host_port: "4000", container_port: "4000"}]
      },
      client: %{
        network_driver: "ipnet"
      },
      protocol: "inet",
      expected_result: :blocked
    })
  end

  test "container on internal=true and icc=true networks cannot access a published port from another container" do
    public_port_connectivity_test(%{
      network_server: %{
        name: "testnet0",
        subnet: "10.13.37.0/24",
        type: "loopback"
      },
      network_client: %{
        name: "testnet1",
        subnet: "10.13.38.0/24",
        type: "loopback",
        internal: true,
        icc: true
      },
      server: %{
        network_driver: "ipnet",
        public_ports: [%{interfaces: [], host_port: "4000", container_port: "4000"}]
      },
      client: %{
        network_driver: "ipnet"
      },
      protocol: "inet",
      expected_result: :blocked
    })
  end

  test "ports can be published using port ranges as specified in pf.conf(5)" do
    {network_server, network_client} =
      create_inter_container_networks(%{
        network_server: %{
          name: "testnet0",
          subnet: "10.13.37.0/24",
          type: "loopback"
        },
        network_client: %{
          name: "testnet1",
          subnet: "10.13.38.0/24",
          type: "loopback"
        }
      })

    # Starting server (listening on port 4000)
    {container_id, endpoint, listen4000_conn} =
      start_nc_server_container(
        %{
          network_driver: "ipnet",
          public_ports: [%{interfaces: [], host_port: "5000:6000", container_port: "4000:*"}]
        },
        network_server,
        "inet"
      )

    # Start additional servers within the same container (listening on port 4500 and 5000)
    listener_config = fn port ->
      %{container_id: container_id, cmd: shell("nc -l #{port}"), attach: false}
    end

    :timer.sleep(500)

    %{id: exec_id} = TestHelper.exec_create(listener_config.(4500))

    {:ok, _stream_ref, listen4500_conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: false})

    %{id: exec_id} = TestHelper.exec_create(listener_config.(5000))

    {:ok, _stream_ref, listen5000_conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: false})

    # Verification:
    timeout = 5_000

    config_client = %{
      name: "client",
      ip_address: "<auto>",
      ip_address6: "",
      network_driver: "ipnet",
      network: network_client.id,
      cmd: ["/bin/sh", "-c", cmd_client("inet", endpoint, 4500)]
    }

    {_, _, _output} = TestHelper.container_valid_run(config_client)
    assert TestHelper.receive_frame(listen4500_conn, timeout) == {:text, "traffic\n"}

    config_client = %{config_client | cmd: ["/bin/sh", "-c", cmd_client("inet", endpoint, 5000)]}
    {_, _, _output} = TestHelper.container_valid_run(config_client)
    assert TestHelper.receive_frame(listen5000_conn, timeout) == {:text, "traffic\n"}

    config_client = %{config_client | cmd: ["/bin/sh", "-c", cmd_client("inet", endpoint, 4000)]}
    {_, _, _output} = TestHelper.container_valid_run(config_client)
    assert TestHelper.receive_frame(listen4000_conn, timeout) == {:text, "traffic\n"}
  end

  test "invalid port publishing specification" do
    config = %{
      name: "server",
      network_driver: "ipnet",
      public_ports: [%{interfaces: [], host_port: "3leet", container_port: "4000"}],
      attach: true,
      cmd: ["/bin/sh", "-c", cmd_server("inet")]
    }

    assert %{message: "invalid port value (should be in the range 0 - 65535)"} ==
             TestHelper.container_create(config)
  end

  defp routes(%{
         "route-table" => %{
           "rt-family" => route_groups
         }
       }) do
    get_route_group("Internet", route_groups)
  end

  defp routes6(%{
         "route-table" => %{
           "rt-family" => route_groups
         }
       }) do
    get_route_group("Internet6", route_groups)
  end

  defp get_route_group(type, route_groups) do
    %{"rt-entry" => routes} =
      Enum.find(route_groups, fn
        %{"address-family" => ^type} -> true
        _ -> false
      end)

    routes
  end

  defp container_connectivity_test(
         %{
           network: config_network,
           client: config_client
         } = testing_config
       ) do
    config_network_default = %{
      icc: true,
      internal: false,
      nat: "<host-gateway>",
      subnet6: "",
      gateway6: ""
    }

    config_network = Map.merge(config_network_default, config_network)
    network = create_network(config_network)

    port =
      case Map.get(testing_config, :expect_fw_block, false) do
        false -> listen_for_traffic()
        true -> listen_for_blocked_traffic()
      end

    config_client_default = %{
      name: "client",
      network: network.id,
      ip_address: "<auto>",
      ip_address6: "",
      expected_exit_code: :anything
    }

    config_client = Map.merge(config_client_default, config_client)

    config_client =
      Map.put(config_client, :cmd, [
        "/bin/sh",
        "-c",
        "host -W 1 freebsd.org 1.1.1.1"
      ])

    {container_id, _, _output} = TestHelper.container_valid_run(config_client)
    %{container_endpoints: [endpoint]} = TestHelper.container_inspect(container_id)

    msg1 = read_tcpdump(port)
    msg2 = read_tcpdump(port)
    assert String.contains?(msg1, "proto UDP")
    assert String.contains?(msg2, "freebsd.org")

    ip2check =
      case {config_network.internal, config_network.nat} do
        {false, ""} -> endpoint.ip_address
        # The only case when NAT applies:
        # Non-internal and with a specified nat-interface:
        {false, _} -> host_ip()
        {true, _} -> endpoint.ip_address
      end

    Logger.warning(ip2check)
    assert String.contains?(msg2, ip2check)

    Port.close(port)
  end

  defp host_ip() do
    {:ok, interface} = Kleened.Core.FreeBSD.host_gateway_interface()

    ip =
      Kleened.Core.OS.shell!("ifconfig #{interface} | grep inet")
      |> String.split(" ")
      |> Enum.at(1)

    ip
  end

  defp listen_for_blocked_traffic() do
    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :stderr_to_stdout,
          :binary,
          :exit_status,
          {:args, ["-c", "tcpdump -l -n -vv -ttt -i pflog0"]},
          {:line, 1024}
        ]
      )

    msg =
      receive do
        {^port, msg} -> msg
      after
        2_000 ->
          Logger.warning("tcpdump not responding")
      end

    assert {:data, {:eol, <<"tcpdump: listening on", _::binary>>}} = msg
    port
  end

  defp listen_for_traffic() do
    {:ok, interface} = Kleened.Core.FreeBSD.host_gateway_interface()

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :stderr_to_stdout,
          :binary,
          :exit_status,
          {:args, ["-c", "tcpdump -l -n -vv -i #{interface} udp and dst 1.1.1.1"]},
          {:line, 1024}
        ]
      )

    msg =
      receive do
        {^port, msg} -> msg
      after
        2_000 ->
          Logger.warning("tcpdump not responding")
      end

    assert {:data, {:eol, <<"tcpdump: listening on", _::binary>>}} = msg
    port
  end

  defp read_tcpdump(port) do
    receive do
      {^port, {:data, {:eol, msg}}} ->
        msg

      {^port, msg} ->
        msg

      msg ->
        Logger.warning("Non-tcpdump message received: #{inspect(msg)}")
        read_tcpdump(port)
    after
      1_000 ->
        Logger.warning("Timed out while reading from tcp-dump")
        "tcpdump timeout"
    end
  end

  defp default_ip("inet"), do: "<auto>"
  defp default_ip("inet6"), do: ""

  defp default_ip6("inet"), do: ""
  defp default_ip6("inet6"), do: "<auto>"

  defp shell(cmd), do: ["/bin/sh", "-c", cmd]

  defp cmd_server("inet"), do: "nc -l 4000"
  defp cmd_server("inet6"), do: "sleep 1 && nc -6 -l 4000"

  defp cmd_client(ip_proto, endpoint, port \\ 4000)

  defp cmd_client("inet", endpoint, port),
    do: "echo \"traffic\" | nc -v -w 2 -N #{endpoint.ip_address} #{port}"

  defp cmd_client("inet6", endpoint, port),
    do: "sleep 1 && echo \"traffic\" | nc -v -w 2 -N #{endpoint.ip_address6} #{port}"

  defp create_inter_container_networks(%{network: config_network}) do
    network = create_network(config_network)
    {network, network}
  end

  defp create_inter_container_networks(%{
         network_server: config_server,
         network_client: config_client
       }) do
    server = create_network(config_server)
    client = create_network(config_client)
    {server, client}
  end

  defp inter_container_connectivity_test(
         %{
           server: config_server,
           client: config_client,
           protocol: protocol
         } = config
       ) do
    {network_server, network_client} = create_inter_container_networks(config)

    {_container_id, endpoint, server_conn} =
      start_nc_server_container(config_server, network_server, protocol)

    config_client =
      Map.merge(
        %{
          name: "client",
          ip_address: default_ip(protocol),
          ip_address6: default_ip6(protocol),
          network: network_client.id,
          cmd: ["/bin/sh", "-c", cmd_client(protocol, endpoint)]
        },
        config_client
      )

    verify_inter_container_results(
      server_conn,
      network_server,
      config,
      config_server,
      config_client,
      protocol
    )
  end

  defp public_port_connectivity_test(
         %{
           server: config_server,
           client: config_client,
           protocol: protocol
         } = config
       ) do
    {network_server, network_client} = create_inter_container_networks(config)

    {_container_id, server_endpoint, server_conn} =
      start_nc_server_container(config_server, network_server, protocol)

    config_client =
      Map.merge(
        %{
          name: "client",
          ip_address: default_ip(protocol),
          ip_address6: default_ip6(protocol),
          network: network_client.id,
          cmd: ["/bin/sh", "-c", cmd_client(protocol, server_endpoint, 4000)]
        },
        config_client
      )

    verify_inter_container_results(
      server_conn,
      network_server,
      config,
      config_server,
      config_client,
      protocol
    )
  end

  defp start_nc_server_container(config_server, network_server, protocol) do
    config_server =
      Map.merge(
        %{
          name: "server",
          ip_address: default_ip(protocol),
          ip_address6: default_ip6(protocol),
          attach: true,
          network: network_server.id,
          cmd: ["/bin/sh", "-c", cmd_server(protocol)]
        },
        config_server
      )

    {container_id, _, server_conn} = TestHelper.container_valid_run_async(config_server)

    assert TestHelper.receive_frame(server_conn, 1_000) ==
             {:text, "{\"data\":\"\",\"message\":\"\",\"msg_type\":\"starting\"}"}

    endpoint = MetaData.get_endpoint(container_id, network_server.id)

    {container_id, endpoint, server_conn}
  end

  defp verify_inter_container_results(
         server_conn,
         network_server,
         config,
         config_server,
         config_client,
         protocol
       ) do
    case Map.get(config, :expected_result, :success) do
      # This is preferable but is quite sensitive/unstable w.r.t. captured packets etc.
      :blocked ->
        port = listen_for_blocked_traffic()
        config_client = Map.put(config_client, :expected_exit_code, 1)

        {container_id, _, output} = TestHelper.container_valid_run(config_client)
        netcat_output = Enum.join(output, "")

        assert String.contains?(netcat_output, "Permission denied")

        %{container_endpoints: [endpoint]} = TestHelper.container_inspect(container_id)

        ip2check =
          case protocol do
            "inet" -> endpoint.ip_address
            "inet6" -> endpoint.ip_address6
          end

        msg1 = read_tcpdump(port)
        msg2 = read_tcpdump(port)
        assert String.contains?(msg1, "proto TCP")
        assert String.contains?(msg2, ip2check)

      :timeout ->
        config_client = Map.put(config_client, :expected_exit_code, 1)

        {_container_id, _, output} = TestHelper.container_valid_run(config_client)
        netcat_output = Enum.join(output, "")

        assert String.contains?(netcat_output, "Operation timed out")

      :success ->
        timeout = 5_000
        {_container_id, _, _output} = TestHelper.container_valid_run(config_client)

        if config_server.network_driver == "vnet" and
             (network_server.gateway != "" or network_server.gateway6 != "") do
          assert {:text, <<"add net default: gateway", _::binary>>} =
                   TestHelper.receive_frame(server_conn, timeout)
        end

        assert TestHelper.receive_frame(server_conn, timeout) == {:text, "traffic\n"}
        assert {:close, 1000, _} = TestHelper.receive_frame(server_conn, timeout)
    end
  end

  defp netstat_in_container(config) do
    all_in_one_netstat =
      "echo \"SPLIT HERE\" && netstat --libxo json -rn && echo \"SPLIT HERE\" && netstat --libxo json -i"

    config_default = %{
      name: "nettest",
      cmd: ["/bin/sh", "-c", all_in_one_netstat],
      ip_address: "<auto>",
      ip_adress6: ""
    }

    config = Map.merge(config_default, config)

    {container_id, _, output} = TestHelper.container_valid_run(config)

    [_init_stuff, route_info, interface_info] =
      Enum.join(output, "") |> String.split("SPLIT HERE\n")

    %{"statistics" => %{"route-information" => routing}} = Jason.decode!(route_info)

    %{"statistics" => %{"interface" => addresses}} = Jason.decode!(interface_info)
    {container_id, routing, addresses}
  end

  defp create_network(config) do
    api_spec = Kleened.API.Spec.spec()

    config_default = %{
      name: "testnet",
      subnet: "172.18.0.0/16",
      subnet6: "",
      type: "loopback",
      gateway: "",
      gateway6: "",
      internal: false,
      icc: true
    }

    config = Map.merge(config_default, config)
    %{id: network_id} = TestHelper.network_create(config)
    network = MetaData.get_network(network_id)
    network_inspected = TestHelper.network_inspect(network.name)
    assert_schema(network_inspected, "NetworkInspect", api_spec)

    assert network.name == config.name
    assert network.id == network_inspected.network.id
    assert network.name == network_inspected.network.name
    assert interface_exists?(network.interface)
    network
  end

  defp failing_to_connect_container(networks, driver) do
    %{id: container_id} =
      TestHelper.container_create(%{
        name: "nettest",
        network: "",
        network_driver: driver
      })

    Enum.map(networks, &TestHelper.network_connect(&1, container_id))
  end

  defp interface_exists?(interface_name) do
    {output_json, 0} = OS.cmd(["/usr/bin/netstat", "--libxo", "json", "-n", "-I", interface_name])

    {:ok, %{"statistics" => %{"interface" => if_properties}}} = Jason.decode(output_json)
    # No properties => no interface named 'interface_name' exists
    length(if_properties) != 0
  end

  defp remove_link_addresses(addresses) do
    Enum.filter(addresses, fn %{"network" => network} ->
      String.slice(network, 0, 6) != "<Link#"
    end)
  end

  defp only_ip_addresses(addresses) do
    Enum.filter(addresses, fn %{"address" => address} ->
      case CIDR.parse(address) do
        %CIDR{} -> true
        _ -> false
      end
    end)
  end

  defp host_addresses() do
    {output, 0} = OS.cmd(~w"/usr/bin/netstat --libxo json -i")
    %{"statistics" => %{"interface" => addresses}} = Jason.decode!(output)
    trim_adresses(addresses)
  end

  defp trim_adresses(addresses) do
    Enum.map(addresses, fn address ->
      Map.drop(address, ["flags", "sent-packets", "received-packets"])
    end)
  end

  defp filter_by_interface(addresses, interface) do
    Enum.filter(addresses, fn %{"network" => network, "name" => name} ->
      # != "<link#" to avoid entries related to '<Link#n>' networks
      String.slice(network, 0, 6) != "<Link#" and name == interface
    end)
  end

  defp address_mapset(addresses) do
    addresses
    |> Enum.map(fn %{"address" => address, "network" => network} ->
      %{address: address, network: network}
    end)
    |> MapSet.new()
  end
end
