defmodule NetworkTest do
  use ExUnit.Case
  alias Jocker.Engine.{Network, Config, Utils, MetaData, Container, Exec}
  alias Jocker.API.Schemas.NetworkConfig

  test "default interface is not defined at startup" do
    Utils.destroy_interface("jocker0")
    Config.delete("default_network_name")

    assert not Utils.interface_exists("jocker0")

    Config.put("default_network_name", "default")
  end

  test "create, get and remove a new network" do
    Utils.destroy_interface("jocker1")

    assert {:ok, %Network{name: "testnetwork"} = test_network} =
             Network.create(%NetworkConfig{
               name: "testnetwork",
               subnet: "172.18.0.0/16",
               ifname: "jocker1",
               driver: "loopback"
             })

    assert Utils.interface_exists("jocker1")
    assert Network.inspect_("testnetwork") == test_network
    assert Network.inspect_(String.slice(test_network.id, 0, 4)) == test_network
    assert Network.remove("testnetwork") == {:ok, test_network.id}
    assert not Utils.interface_exists("jocker1")
    assert MetaData.get_network(test_network.id) == :not_found
  end

  test "listing networks" do
    Utils.destroy_interface("jocker1")

    assert [%Network{id: "host"}] = Network.list()

    {:ok, network} =
      Network.create(%NetworkConfig{
        name: "testnetwork",
        subnet: "172.18.0.0/16",
        ifname: "jocker1",
        driver: "loopback"
      })

    assert [
             %Network{id: "host"},
             %Network{name: "testnetwork"}
           ] = Network.list()

    assert Network.remove("testnetwork") == {:ok, network.id}
  end

  test "remove a non-existing network" do
    assert {:ok, test_network} =
             Network.create(%NetworkConfig{
               name: "testnetwork",
               subnet: "172.18.0.0/16",
               ifname: "jocker1",
               driver: "loopback"
             })

    assert Network.remove("testnetwork") == {:ok, test_network.id}
    assert Network.remove("testnetwork") == {:error, "network not found."}
  end

  test "create a network with same name twice" do
    assert {:ok, _test_network} =
             Network.create(%NetworkConfig{
               name: "testnetwork",
               subnet: "172.18.0.0/16",
               ifname: "jocker1",
               driver: "loopback"
             })

    assert {:error, "network name is already taken"} =
             Network.create(%NetworkConfig{
               name: "testnetwork",
               subnet: "172.19.0.0/16",
               ifname: "jocker2",
               driver: "loopback"
             })

    Network.remove("testnetwork")
  end

  test "try to create a network with a invalid subnet" do
    assert {:error, "invalid subnet"} =
             Network.create(%NetworkConfig{
               name: "testnetwork",
               subnet: "172.18.0.0-16",
               ifname: "jocker1",
               driver: "loopback"
             })
  end

  test "connect and disconnect a container to a network" do
    network_if = "jocker1"

    {:ok, test_network} =
      Network.create(%NetworkConfig{
        name: "testnet",
        subnet: "172.19.0.0/24",
        ifname: network_if,
        driver: "loopback"
      })

    opts = %{
      cmd: ["/usr/bin/netstat", "--libxo", "json", "-4", "-n", "-I", network_if]
    }

    {:ok, %Container{id: id}} = TestHelper.create_container("network_test", opts)

    Network.connect(id, "testnet")
    {:ok, exec_id} = Exec.create(id)
    Jocker.Engine.Exec.start(exec_id, %{attach: true, start_container: true})
    {:ok, output} = Jason.decode(TestHelper.collect_container_output(exec_id))
    assert %{"statistics" => %{"interface" => [%{"address" => "172.19.0.0"}]}} = output
    assert Network.remove("testnet") == {:ok, test_network.id}
    Container.destroy(id)
  end

  test "using 'host' network instead of 'default'" do
    opts = %{
      networks: ["host"],
      cmd: ["/usr/bin/netstat", "--libxo", "json", "-i", "-4"]
    }

    {:ok, %Container{id: id}} = TestHelper.create_container("network_test2", opts)

    {output_json, 0} = System.cmd("/usr/bin/netstat", ["--libxo", "json", "-i", "-4"])
    ips_before = ips_on_all_interfaces(output_json)

    {:ok, exec_id} = Exec.create(id)
    Jocker.Engine.Exec.start(exec_id, %{attach: true, start_container: true})
    output_json = TestHelper.collect_container_output(exec_id)

    ips_after = ips_on_all_interfaces(output_json)

    assert MapSet.size(ips_before) == MapSet.size(ips_after)

    Container.destroy(id)
  end

  test "connectivity using default interface" do
    {:ok, test_network} =
      Network.create(%NetworkConfig{
        name: "testnet",
        subnet: "172.18.0.0/16",
        ifname: "jocker1",
        driver: "loopback"
      })

    opts = %{
      cmd: ["/usr/bin/host", "-t", "A", "freebsd.org", "1.1.1.1"],
      networks: ["testnet"]
    }

    {:ok, %Container{id: id}} = TestHelper.create_container("network_test3", opts)
    {:ok, exec_id} = Exec.create(id)
    Jocker.Engine.Exec.start(exec_id, %{attach: true, start_container: true})

    output =
      receive do
        {:container, ^exec_id, {:jail_output, msg}} -> msg
      end

    assert output ==
             "Using domain server:\nName: 1.1.1.1\nAddress: 1.1.1.1#53\nAliases: \n\nfreebsd.org has address 96.47.72.84\n"

    assert Network.remove("testnet") == {:ok, test_network.id}
    Container.destroy(id)
  end

  defp ips_on_all_interfaces(netstat_output_json) do
    {:ok, %{"statistics" => %{"interface" => if_info}}} = Jason.decode(netstat_output_json)
    MapSet.new(Enum.map(if_info, &Map.get(&1, "address")))
  end
end
