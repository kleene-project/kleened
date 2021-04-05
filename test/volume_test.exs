defmodule VolumeTest do
  use ExUnit.Case
  alias Jocker.Engine.{MetaData, Config, Container, Volume, Layer, Network}
  @moduletag :capture_log

  setup_all do
    Application.stop(:jocker)
    TestHelper.clear_zroot()
    start_supervised(Config)
    start_supervised(MetaData)
    start_supervised(Layer)
    start_supervised(Network)

    start_supervised(
      {DynamicSupervisor, name: Jocker.Engine.ContainerPool, strategy: :one_for_one}
    )

    :ok
  end

  test "test filesystem operations when creating and deleting volumes" do
    %Volume{dataset: dataset, mountpoint: mountpoint} = volume = Volume.create_volume("test")
    assert {:ok, %File.Stat{:type => :directory}} = File.stat(mountpoint)
    assert {"#{dataset}\n", 0} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
    Volume.destroy_volume(volume)
    assert {:error, :enoent} = File.stat(mountpoint)
    assert {"", 1} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
  end

  test "listing of volumes" do
    vol1 = Volume.create_volume("test")
    assert [vol1] == MetaData.list_volumes()
    vol2 = Volume.create_volume("lol")
    assert [vol2, vol1] == MetaData.list_volumes()
    vol1_new_created = Volume.create_volume("test")
    assert [vol1_new_created, vol2] == MetaData.list_volumes()
    Volume.destroy_volume(vol1)
    assert [vol2] == MetaData.list_volumes()
    Volume.destroy_volume(vol2)
  end

  test "verify volume binding" do
    # use /mnt since this is empty in the basejail by default
    location = "/mnt"
    file = "/mnt/test"
    volume = Volume.create_volume("testvol")

    {:ok, %Container{id: id} = con} =
      Jocker.Engine.Container.create(cmd: ["/usr/bin/touch", file])

    Jocker.Engine.Container.attach(id)
    :ok = Volume.bind_volume(con, volume, location)
    Jocker.Engine.Container.start(id)

    receive do
      {:container, ^id, {:shutdown, :jail_stopped}} -> :ok
    end

    assert {:ok, %File.Stat{:type => :regular}} = File.stat(Path.join(volume.mountpoint, "test"))
    Volume.destroy_volume(volume)
  end
end
