defmodule NetworkTest do
  use ExUnit.Case
  alias Jocker.Engine.{Network, Config, Utils, MetaData, Container}

  setup_all do
    Application.stop(:jocker)
    TestHelper.clear_zroot()
    {:ok, _pid} = start_supervised(Config)
    {:ok, _pid} = start_supervised(MetaData)
    :ok
  end

  setup do
    MetaData.clear_tables()
    :ok
  end

  test "default interface is created at startup" do
    Utils.destroy_interface("jocker0")
    {:ok, _pid} = Network.start_link([])

    assert Utils.interface_exists("jocker0")
  end

  test "default interface is not defined at startup" do
    Utils.destroy_interface("jocker0")
    Config.delete("default_network_name")
    {:ok, _pid} = Network.start_link([])

    assert not Utils.interface_exists("jocker0")

    Config.put("default_network_name", "default")
  end

  test "create, get and remove a new network" do
    Utils.destroy_interface("jocker1")
    {:ok, _pid} = Network.start_link([])

    assert {:ok, %Network{name: "testnetwork"} = test_network} =
             Network.create("testnetwork", subnet: "172.18.0.0/16", ifname: "jocker1")

    assert Utils.interface_exists("jocker1")
    assert Network.inspect_("testnetwork") == test_network
    assert Network.inspect_(String.slice(test_network.id, 0, 4)) == test_network
    assert Network.remove("testnetwork") == {:ok, test_network.id}
    assert not Utils.interface_exists("jocker1")
    assert MetaData.get_network(test_network.id) == :not_found
  end

  test "listing networks" do
    Utils.destroy_interface("jocker1")
    {:ok, _pid} = Network.start_link([])

    assert [%Network{id: "host"}, %Network{name: "default"}] = Network.list()

    {:ok, _network} = Network.create("testnetwork", subnet: "172.18.0.0/16", ifname: "jocker1")

    assert [
             %Network{id: "host"},
             %Network{name: "default"},
             %Network{name: "testnetwork"}
           ] = Network.list()
  end

  test "remove a non-existing network" do
    {:ok, _pid} = Network.start_link([])

    assert {:ok, test_network} =
             Network.create("testnetwork", subnet: "172.18.0.0/16", ifname: "jocker1")

    assert Network.remove("testnetwork") == {:ok, test_network.id}
    assert Network.remove("testnetwork") == {:error, "network not found."}
  end

  test "create a network with same name twice" do
    {:ok, _pid} = Network.start_link([])

    assert {:ok, test_network} =
             Network.create("testnetwork", subnet: "172.18.0.0/16", ifname: "jocker1")

    assert {:error, "network name is already taken"} =
             Network.create("testnetwork", subnet: "172.19.0.0/16", ifname: "jocker2")

    Network.remove("testnetwork")
  end

  test "try to create a network with a invalid subnet" do
    {:ok, _pid} = Network.start_link([])

    assert {:error, "invalid subnet"} =
             Network.create("testnetwork", subnet: "172.18.0.0-16", ifname: "jocker1")
  end

  test "connect and disconnect a container to a network" do
    {:ok, _pid} = Jocker.Engine.Layer.start_link([])
    {:ok, _pid} = Network.start_link([])

    start_supervised(
      {DynamicSupervisor, name: Jocker.Engine.ContainerPool, strategy: :one_for_one}
    )

    network_if = "jocker1"
    Network.create("testnet", subnet: "172.19.0.0/24", ifname: network_if)

    opts = [
      cmd: ["/usr/bin/netstat", "--libxo", "json", "-4", "-n", "-I", network_if]
    ]

    {:ok, %Container{id: id}} = Container.create(opts)

    Network.connect(id, "testnet")
    :ok = Container.attach(id)
    Container.start(id)
    {:ok, output} = Jason.decode(TestHelper.collect_container_output(id))
    assert %{"statistics" => %{"interface" => [%{"address" => "172.19.0.0"}]}} = output
    Network.remove("testnetwork")
  end

  test "using 'host' network instead of 'default'" do
    {:ok, _pid} = Jocker.Engine.Layer.start_link([])
    {:ok, _pid} = Network.start_link([])

    {:ok, _pid} =
      start_supervised(
        {DynamicSupervisor, name: Jocker.Engine.ContainerPool, strategy: :one_for_one}
      )

    opts = [
      networks: ["host"],
      cmd: ["/usr/bin/netstat", "--libxo", "json", "-i", "-4"]
    ]

    {:ok, %Container{id: id}} = Container.create(opts)

    {output_json, 0} = System.cmd("/usr/bin/netstat", ["--libxo", "json", "-i", "-4"])
    ips_before = ips_on_all_interfaces(output_json)

    :ok = Container.attach(id)
    Container.start(id)
    output_json = TestHelper.collect_container_output(id)

    ips_after = ips_on_all_interfaces(output_json)

    assert MapSet.size(ips_before) == MapSet.size(ips_after)

    Container.destroy(id)
  end

  test "connectivity using default interface" do
    {:ok, _pid} = Jocker.Engine.Layer.start_link([])
    {:ok, _pid} = Network.start_link([])

    start_supervised(
      {DynamicSupervisor, name: Jocker.Engine.ContainerPool, strategy: :one_for_one}
    )

    opts = [
      cmd: ["/usr/bin/host", "-t", "A", "freebsd.org", "1.1.1.1"]
    ]

    {:ok, %Container{id: id}} = Container.create(opts)
    :ok = Container.attach(id)
    Container.start(id)

    output =
      receive do
        {:container, ^id, msg} -> msg
      end

    assert output ==
             "Using domain server:\nName: 1.1.1.1\nAddress: 1.1.1.1#53\nAliases: \n\nfreebsd.org has address 96.47.72.84\n"

    Container.destroy(id)
  end

  defp ips_on_all_interfaces(netstat_output_json) do
    {:ok, %{"statistics" => %{"interface" => if_info}}} = Jason.decode(netstat_output_json)
    MapSet.new(Enum.map(if_info, &Map.get(&1, "address")))
  end
end
