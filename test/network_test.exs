defmodule NetworkTest do
  use ExUnit.Case
  alias Jocker.Engine.Network
  alias Jocker.Engine.Config
  alias Jocker.Engine.Utils
  alias Jocker.Engine.MetaData
  alias Jocker.Structs

  setup_all do
    Application.stop(:jocker)
    {:ok, _cfg_pid} = Config.start_link([])
    {:ok, _metadata_pid} = MetaData.start_link([])
    :ok
  end

  test "default interface is created at startup" do
    MetaData.clear_tables()
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

  test "create a and remove a new network" do
    Utils.destroy_interface("jocker1")
    {:ok, _pid} = Network.start_link([])

    assert {:ok, test_network} =
             Network.create("testnetwork", :loopback, subnet: "172.18.0.0/16", if_name: "jocker1")

    assert Utils.interface_exists("jocker1")
    assert %Structs.Network{:name => "testnetwork"} = test_network

    assert Network.inspect_("testnetwork") == test_network
    assert Network.inspect_(String.slice(test_network.id, 0, 4)) == test_network
    assert Network.remove("testnetwork") == :ok
    assert not Utils.interface_exists("jocker1")
    assert MetaData.get_network(test_network.id) == :not_found
  end

  test "remove a non-existing network" do
    {:ok, _pid} = Network.start_link([])

    assert {:ok, test_network} =
             Network.create("testnetwork", :loopback, subnet: "172.18.0.0/16", if_name: "jocker1")

    assert Network.remove("testnetwork") == :ok
    assert Network.remove("testnetwork") == {:error, "network not found."}
  end

  test "create a network with same name twice" do
    {:ok, _pid} = Network.start_link([])

    assert {:ok, test_network} =
             Network.create("testnetwork", :loopback, subnet: "172.18.0.0/16", if_name: "jocker1")

    assert {:error, "network name is already taken"} =
             Network.create("testnetwork", :loopback, subnet: "172.19.0.0/16", if_name: "jocker2")

    Network.remove("testnetwork")
  end

  test "try to create a network with a invalid subnet" do
    {:ok, _pid} = Network.start_link([])

    assert {:error, "invalid subnet"} =
             Network.create("testnetwork", :loopback, subnet: "172.18.0.0-16", if_name: "jocker1")
  end
end
