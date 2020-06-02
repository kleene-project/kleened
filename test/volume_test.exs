defmodule VolumeTest do
  use ExUnit.Case
  require Jocker.Engine.Config
  import Jocker.Engine.Records
  import Jocker.Engine.Volume
  alias Jocker.Engine.MetaData
  @moduletag :capture_log

  setup_all do
    Application.stop(:jocker)
    Jocker.Engine.ZFS.clear_zroot()
    start_supervised({Jocker.Engine.MetaData, [file: Jocker.Engine.Config.metadata_db()]})
    start_supervised(Jocker.Engine.Layer)
    start_supervised({Jocker.Engine.Network, [{"10.13.37.1", "10.13.37.255"}, "jocker0"]})
    initialize()
  end

  setup do
    on_exit(fn -> MetaData.clear_tables() end)
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
    volume(name: name) = vol2 = create_volume("lol")
    assert [vol2, vol1] == MetaData.list_volumes()
    vol1_new_created = create_volume("test")
    assert [vol1_new_created, vol2] == MetaData.list_volumes()
    destroy_volume(vol1)
    assert [vol2] == MetaData.list_volumes()
  end

  test "verify volume binding" do
    # use /mnt since this is empty in the basejail by default
    location = "/mnt"
    file = "/mnt/test"
    volume(mountpoint: mountpoint) = vol = create_volume("testvol")
    {:ok, container_pid} = Jocker.Engine.Container.create(cmd: ["/usr/bin/touch", file])
    Jocker.Engine.Container.attach(container_pid)
    con = Jocker.Engine.Container.metadata(container_pid)
    :ok = bind_volume(con, vol, location)
    Jocker.Engine.Container.start(container_pid)

    receive do
      {:container, ^container_pid, {:shutdown, :jail_stopped}} -> :ok
    end

    assert {:ok, %File.Stat{:type => :regular}} = File.stat(Path.join(mountpoint, "test"))
  end
end
