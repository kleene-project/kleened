defmodule VolumeTest do
  use ExUnit.Case
  import Jocker.Engine.Records
  import Jocker.Engine.Volume
  alias Jocker.Engine.MetaData
  alias Jocker.Engine.Config
  @moduletag :capture_log

  setup_all do
    Application.stop(:jocker)
    TestUtils.clear_zroot()
    start_supervised(Config)
    start_supervised(Jocker.Engine.MetaData)
    start_supervised(Jocker.Engine.Layer)
    start_supervised(Jocker.Engine.Network)

    start_supervised(
      {DynamicSupervisor, name: Jocker.Engine.ContainerPool, strategy: :one_for_one}
    )

    :ok
  end

  test "test filesystem operations when creating and deleting volumes" do
    volume(dataset: dataset, mountpoint: mountpoint) = vol = create_volume("test")
    assert {:ok, %File.Stat{:type => :directory}} = File.stat(mountpoint)
    assert {"#{dataset}\n", 0} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
    destroy_volume(vol)
    assert {:error, :enoent} = File.stat(mountpoint)
    assert {"", 1} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
  end

  test "listing of volumes" do
    vol1 = create_volume("test")
    assert [vol1] == MetaData.list_volumes()
    vol2 = create_volume("lol")
    assert [vol2, vol1] == MetaData.list_volumes()
    vol1_new_created = create_volume("test")
    assert [vol1_new_created, vol2] == MetaData.list_volumes()
    destroy_volume(vol1)
    assert [vol2] == MetaData.list_volumes()
    destroy_volume(vol2)
  end

  test "verify volume binding" do
    # use /mnt since this is empty in the basejail by default
    location = "/mnt"
    file = "/mnt/test"
    volume(mountpoint: mountpoint) = vol = create_volume("testvol")

    {:ok, container(id: id) = con} = Jocker.Engine.Container.create(cmd: ["/usr/bin/touch", file])

    Jocker.Engine.Container.attach(id)
    :ok = bind_volume(con, vol, location)
    Jocker.Engine.Container.start(id)

    receive do
      {:container, ^id, {:shutdown, :jail_stopped}} -> :ok
    end

    assert {:ok, %File.Stat{:type => :regular}} = File.stat(Path.join(mountpoint, "test"))
    destroy_volume(vol)
  end
end
