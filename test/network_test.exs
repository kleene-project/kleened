defmodule NetworkTest do
  use Jocker.API.ConnCase
  require Logger
  alias Jocker.Engine.{Network, Utils, MetaData, Container, Exec, OS}
  alias Jocker.API.Schemas
  alias Network.EndPoint

  @moduletag :capture_log

  @dns_lookup_cmd ["/usr/bin/host", "-t", "A", "freebsd.org", "1.1.1.1"]
  @dns_lookup_success "Using domain server:\nName: 1.1.1.1\nAddress: 1.1.1.1#53\nAliases: \n\nfreebsd.org has address 96.47.72.84\n"
  @dns_lookup_failure ";; connection timed out; no servers could be reached\n"

  setup do
    on_exit(fn ->
      Jocker.Engine.MetaData.list_containers()
      |> Enum.map(fn %{id: id} -> Container.remove(id) end)
    end)

    on_exit(fn ->
      Jocker.Engine.MetaData.list_networks(:exclude_host)
      |> Enum.map(fn %{id: id} -> Jocker.Engine.Network.remove(id) end)
    end)

    :ok
  end

  test "create, get and remove a new network", %{api_spec: api_spec} do
    Utils.destroy_interface("jocker1")

    network = create_network(api_spec, %{ifname: "jocker1", driver: "loopback"})

    assert network.name == "testnet"

    assert Utils.interface_exists("jocker1")
    assert Network.inspect_(network.name) == network
    assert Network.inspect_(String.slice(network.id, 0, 4)) == network
    assert TestHelper.network_destroy(api_spec, network.name) == %{id: network.id}
    assert not Utils.interface_exists("jocker1")
    assert MetaData.get_network(network.id) == :not_found
  end

  test "listing networks", %{api_spec: api_spec} do
    Utils.destroy_interface("jocker1")

    assert [%{id: "host"}] = TestHelper.network_list(api_spec)

    network = create_network(api_spec, %{ifname: "jocker1", driver: "loopback"})

    assert [
             %{id: "host"},
             %{name: "testnet"}
           ] = TestHelper.network_list(api_spec)

    assert TestHelper.network_destroy(api_spec, network.name) == %{id: network.id}
  end

  test "remove a non-existing network", %{api_spec: api_spec} do
    network = create_network(api_spec, %{ifname: "jocker1", driver: "loopback"})
    assert TestHelper.network_destroy(api_spec, network.name) == %{id: network.id}
    assert TestHelper.network_destroy(api_spec, network.name) == %{message: "network not found."}
  end

  test "create a network with same name twice", %{api_spec: api_spec} do
    network = create_network(api_spec, %{ifname: "jocker1", driver: "loopback"})

    assert %{message: "network name is already taken"} ==
             TestHelper.network_create(api_spec, %{
               ifname: "jocker2",
               subnet: "172.19.0.0/16",
               driver: "loopback"
             })

    assert TestHelper.network_destroy(api_spec, network.name) == %{id: network.id}
  end

  test "try to create a network with a invalid subnet", %{api_spec: api_spec} do
    assert %{message: "invalid subnet"} =
             TestHelper.network_create(api_spec, %{
               subnet: "172.18.0.0-16",
               driver: "loopback"
             })
  end

  test "try to disconnect twice", %{api_spec: api_spec} do
    network = create_network(api_spec, %{driver: "loopback"})

    %{id: container_id} =
      TestHelper.container_create(api_spec, "network_test", %{
        cmd: ["/bin/sleep", "10"],
        networks: [network.name]
      })

    assert :ok == TestHelper.network_disconnect(api_spec, container_id, network.id)

    assert %{message: "endpoint configuration not found"} ==
             TestHelper.network_disconnect(api_spec, container_id, network.id)

    cleanup(api_spec, container_id, network)
  end

  test "create a container using the host network", %{api_spec: api_spec} do
    opts = %{
      networks: ["host"],
      cmd: ["/usr/bin/netstat", "--libxo", "json", "-i", "-4"]
    }

    %{id: id} = TestHelper.container_create(api_spec, "network_test2", opts)

    {output_json, 0} = System.cmd("/usr/bin/netstat", ["--libxo", "json", "-i", "-4"])
    ips_before = ips_on_all_interfaces(output_json)

    {:ok, exec_id} = exec_run(id, %{attach: true, start_container: true})
    output_json = TestHelper.collect_container_output(exec_id)

    ips_after = ips_on_all_interfaces(output_json)

    assert MapSet.size(ips_before) == MapSet.size(ips_after)

    Container.remove(id)
  end

  test "connect loopback network when container is created", %{api_spec: api_spec} do
    network =
      create_network(api_spec, %{subnet: "172.19.0.0/16", ifname: "jocker1", driver: "loopback"})

    opts = %{
      cmd: ["/usr/bin/netstat", "--libxo", "json", "-4", "-n", "-I", network.loopback_if],
      networks: [network.name]
    }

    %{id: container_id} = TestHelper.container_create(api_spec, "network_test", opts)

    {:ok, exec_id} = exec_run(container_id, %{attach: true, start_container: true})
    %EndPoint{ip_address: ip} = MetaData.get_endpoint(container_id, network.id)
    {:ok, output} = Jason.decode(TestHelper.collect_container_output(exec_id))
    assert %{"statistics" => %{"interface" => [%{"address" => ^ip}]}} = output
    assert ip_not_on_if(ip, network.loopback_if)

    cleanup(api_spec, container_id, network)
  end

  test "connect loopback network after container creation", %{api_spec: api_spec} do
    network =
      create_network(api_spec, %{ifname: "jocker1", subnet: "172.19.0.0/16", driver: "loopback"})

    opts = %{
      cmd: ["/usr/bin/netstat", "--libxo", "json", "-4", "-n", "-I", network.loopback_if],
      networks: []
    }

    %{id: container_id} = TestHelper.container_create(api_spec, "network_test", opts)

    assert :ok = TestHelper.network_connect(api_spec, "testnet", container_id)

    assert %{message: "container already connected to the network"} ==
             TestHelper.network_connect(api_spec, "testnet", container_id)

    %EndPoint{ip_address: ip} = MetaData.get_endpoint(container_id, network.id)
    {:ok, exec_id} = exec_run(container_id, %{attach: true, start_container: true})
    {:ok, output} = Jason.decode(TestHelper.collect_container_output(exec_id))
    assert %{"statistics" => %{"interface" => [%{"address" => ^ip}]}} = output
    assert ip_not_on_if(ip, network.loopback_if)

    cleanup(api_spec, container_id, network)
  end

  test "connect vnet network when container is created", %{api_spec: api_spec} do
    network = create_network(api_spec, %{driver: "vnet"})

    %{id: container_id} =
      TestHelper.container_create(api_spec, "network_test3", %{
        cmd: ["/bin/sleep", "100"],
        networks: [network.name]
      })

    {:ok, exec_id} = exec_run(container_id, %{attach: true, start_container: true})
    assert receive_jail_output(exec_id) == "add net default: gateway 172.18.0.0\n"
    %EndPoint{epair: epair} = Network.inspect_endpoint(container_id, network.id)
    assert epair != nil

    # This is needed because "jail" adds the epair<N>b AFTER "add net default.." so a race-condition occurs
    :timer.sleep(1_000)
    assert interface_exists?("#{epair}a")

    Container.stop(container_id)
    assert await_jail_output(exec_id, {:shutdown, :jail_stopped})
    assert not interface_exists?("#{epair}a")

    cleanup(api_spec, container_id, network)
  end

  test "connect vnet network after container creation", %{api_spec: api_spec} do
    network = create_network(api_spec, %{driver: "vnet", ifname: "vnet0"})

    %{id: container_id} =
      TestHelper.container_create(api_spec, "network_test3", %{
        cmd: ["/bin/sleep", "100"],
        networks: []
      })

    assert :ok == TestHelper.network_connect(api_spec, "testnet", container_id)
    %EndPoint{epair: nil} = MetaData.get_endpoint(container_id, network.id)
    {:ok, exec_id} = exec_run(container_id, %{attach: true, start_container: true})
    assert receive_jail_output(exec_id) == "add net default: gateway 172.18.0.0\n"
    %EndPoint{epair: epair} = Network.inspect_endpoint(container_id, network.id)

    # This is needed because "jail" adds the epair<N>b AFTER "add net default.." so a race-condition occurs
    :timer.sleep(1_000)
    assert interface_exists?("#{epair}a")

    Container.stop(container_id)
    assert await_jail_output(exec_id, {:shutdown, :jail_stopped})

    assert not interface_exists?("#{epair}a")

    cleanup(api_spec, container_id, network)
  end

  test "try to connect a container to vnet and then loopback network", %{api_spec: api_spec} do
    network1 =
      create_network(api_spec, %{
        driver: "vnet",
        name: "testnet1",
        subnet: "10.13.37.0/24",
        ifname: "vnet1"
      })

    network2 =
      create_network(api_spec, %{
        driver: "loopback",
        name: "testnet2",
        subnet: "10.13.38.0/24",
        ifname: "vnet2"
      })

    %{id: container_id} =
      TestHelper.container_create(api_spec, "network_test3", %{
        cmd: ["/bin/sleep", "10"],
        networks: []
      })

    assert :ok == TestHelper.network_connect(api_spec, network1.id, container_id)
    assert %EndPoint{} = MetaData.get_endpoint(container_id, network1.id)

    assert %{
             message:
               "already connected to a vnet network and containers can't be connected to both vnet and loopback networks"
           } ==
             TestHelper.network_connect(api_spec, network2.id, container_id)

    cleanup(api_spec, container_id, [network1, network2])
  end

  test "create networks with a user-supplied ips", %{api_spec: api_spec} do
    Utils.destroy_interface("jocker1")

    network_vnet =
      create_network(api_spec, %{name: "testvnet", subnet: "10.13.37.0/24", driver: "vnet"})

    network_lo =
      create_network(api_spec, %{name: "testlonet", subnet: "10.13.38.0/24", driver: "loopback"})

    opts = %{
      cmd: ["/usr/bin/netstat", "--libxo", "json", "-4", "-n", "-i"],
      networks: %{
        # We don't use %EndPointConfig{} schema struct because we also need to test conversion of keys from strings to atoms.
        "testlonet" => %{"container" => "dummy", "ip_address" => "10.13.38.42"}
      }
    }

    %{id: container_id} = TestHelper.container_create(api_spec, "network_test", opts)
    {:ok, exec_id} = exec_run(container_id, %{attach: true, start_container: true})
    {:ok, output} = Jason.decode(TestHelper.collect_container_output(exec_id))
    assert %{"statistics" => %{"interface" => [%{"address" => "10.13.38.42"}]}} = output

    TestHelper.network_disconnect(api_spec, container_id, network_lo.id)
    {:ok, exec_id} = exec_run(container_id, %{attach: true, start_container: true})
    {:ok, output} = Jason.decode(TestHelper.collect_container_output(exec_id))
    assert %{"statistics" => %{"interface" => []}} == output

    TestHelper.network_connect(api_spec, network_vnet.id, %{
      container: container_id,
      ip_address: "10.13.37.22"
    })

    {:ok, exec_id} = exec_run(container_id, %{attach: true, start_container: true})
    assert receive_jail_output(exec_id) == "add net default: gateway 10.13.37.0\n"
    {:ok, output} = Jason.decode(TestHelper.collect_container_output(exec_id))
    assert %{"statistics" => %{"interface" => [%{"address" => "10.13.37.22"}]}} = output
  end

  test "exhaust all ips in a network", %{api_spec: api_spec} do
    create_network(api_spec, %{name: "smallnet", subnet: "172.19.0.0/30", driver: "loopback"})

    opts = %{cmd: ["/bin/ls"], networks: ["smallnet"]}

    %{id: _container_id} = TestHelper.container_create(api_spec, "exhaust1", opts)
    %{id: _container_id} = TestHelper.container_create(api_spec, "exhaust2", opts)
    %{id: _container_id} = TestHelper.container_create(api_spec, "exhaust3", opts)
    %{id: _container_id} = TestHelper.container_create(api_spec, "exhaust4", opts)
    %{id: _container_id} = TestHelper.container_create(api_spec, "exhaust5", opts)
  end

  test "connectivity using loopback interface", %{api_spec: api_spec} do
    network = create_network(api_spec, %{driver: "loopback", ifname: "jocker1"})

    %{id: container_id} =
      TestHelper.container_create(
        api_spec,
        "network_test3",
        %{cmd: @dns_lookup_cmd, networks: ["testnet"]}
      )

    {:ok, exec_id} = exec_run(container_id, %{attach: true, start_container: true})

    assert receive_jail_output(exec_id) == @dns_lookup_success

    cleanup(api_spec, container_id, network)
  end

  test "connectivity using vnet interface", %{api_spec: api_spec} do
    network = create_network(api_spec, %{driver: "vnet", ifname: "vnet1"})

    %{id: container_id} =
      TestHelper.container_create(
        api_spec,
        "network_test3",
        %{cmd: @dns_lookup_cmd, networks: ["testnet"]}
      )

    {:ok, exec_id} = exec_run(container_id, %{attach: true, start_container: true})

    assert receive_jail_output(exec_id) == "add net default: gateway 172.18.0.0\n"
    assert receive_jail_output(exec_id) == @dns_lookup_success

    Container.stop(container_id)

    cleanup(api_spec, container_id, network)
  end

  test "disconnect vnet network while the container is running", %{api_spec: api_spec} do
    network = create_network(api_spec, %{driver: "vnet", ifname: "vnet1"})

    %{id: container_id} =
      TestHelper.container_create(
        api_spec,
        "network_test3",
        %{cmd: ["/bin/sleep", "100"], networks: []}
      )

    assert :ok == TestHelper.network_connect(api_spec, network.name, container_id)
    assert %EndPoint{} = MetaData.get_endpoint(container_id, network.id)
    {:ok, exec_id} = exec_run(container_id, %{attach: true, start_container: true})

    assert receive_jail_output(exec_id) == "add net default: gateway 172.18.0.0\n"

    %EndPoint{epair: epair} = Network.inspect_endpoint(container_id, network.id)
    assert interface_exists?("#{epair}a")

    assert :ok == TestHelper.network_disconnect(api_spec, container_id, network.name)

    {:ok, exec_id} =
      exec_run(
        %Schemas.ExecConfig{container_id: container_id, cmd: @dns_lookup_cmd},
        %{attach: true, start_container: false}
      )

    assert receive_jail_output(exec_id) == @dns_lookup_failure

    Container.stop(container_id)
    cleanup(api_spec, container_id, network)
  end

  defp create_network(api_spec, config) do
    %{id: network_id} = TestHelper.network_create(api_spec, config)
    network = MetaData.get_network(network_id)

    case network.driver do
      "loopback" ->
        assert interface_exists?(network.loopback_if)

      "vnet" ->
        assert interface_exists?(network.bridge_if)

      _ ->
        :ok
    end

    network
  end

  defp cleanup(api_spec, container_id, [network1, network2]) do
    assert TestHelper.network_destroy(api_spec, network1.name) == %{id: network1.id}
    cleanup(api_spec, container_id, network2)
  end

  defp cleanup(api_spec, container_id, network) do
    assert TestHelper.network_destroy(api_spec, network.name) == %{id: network.id}

    case network.driver do
      "vnet" -> assert not interface_exists?(network.bridge_if)
      "loopback" -> assert not interface_exists?(network.loopback_if)
      _ -> :ok
    end

    Container.remove(container_id)
  end

  defp exec_run(container_id_or_exec_config, start_opts) do
    {:ok, exec_id} = Exec.create(container_id_or_exec_config)
    Jocker.Engine.Exec.start(exec_id, start_opts)
    {:ok, exec_id}
  end

  defp interface_exists?(interface_name) do
    {output_json, 0} = OS.cmd(["/usr/bin/netstat", "--libxo", "json", "-n", "-I", interface_name])

    {:ok, %{"statistics" => %{"interface" => if_properties}}} = Jason.decode(output_json)
    # No properties => no interface named 'interface_name' exists
    length(if_properties) != 0
  end

  defp ip_not_on_if(ip, network_if) do
    {output_json, 0} =
      System.cmd("/usr/bin/netstat", ["--libxo", "json", "-4", "-n", "-I", network_if])

    {:ok, %{"statistics" => %{"interface" => if_info}}} = Jason.decode(output_json)
    ips = MapSet.new(Enum.map(if_info, &Map.get(&1, "address")))

    MapSet.member?(ips, ip)
  end

  defp ips_on_all_interfaces(netstat_output_json) do
    {:ok, %{"statistics" => %{"interface" => if_info}}} = Jason.decode(netstat_output_json)
    MapSet.new(Enum.map(if_info, &Map.get(&1, "address")))
  end

  defp await_jail_output(exec_id, msg) do
    receive do
      {:container, ^exec_id, ^msg} -> true
    after
      5_000 -> false
    end
  end

  defp receive_jail_output(exec_id) do
    receive do
      {:container, ^exec_id, {:jail_output, msg}} -> msg
    end
  end
end
