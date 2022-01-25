defmodule VolumeTest do
  use ExUnit.Case
  alias Jocker.Engine.{MetaData, Container, Volume}
  @moduletag :capture_log

  setup do
    # Remove networks from previous test
    on_exit(fn ->
      Jocker.Engine.MetaData.list_volumes()
      |> Enum.map(&Volume.destroy/1)
    end)

    :ok
  end

  test "test filesystem operations when creating and deleting volumes" do
    %Volume{dataset: dataset, mountpoint: mountpoint} = volume = Volume.create("test")
    assert {:ok, %File.Stat{:type => :directory}} = File.stat(mountpoint)
    assert {"#{dataset}\n", 0} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
    Volume.destroy(volume.name)
    assert {:error, :enoent} = File.stat(mountpoint)
    assert {"", 1} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
  end

  test "listing of volumes" do
    vol1 = Volume.create("test")
    assert [vol1] == MetaData.list_volumes()
    vol2 = Volume.create("lol")
    assert [vol2, vol1] == MetaData.list_volumes()
    vol1_new_created = Volume.create("test")
    assert [vol1_new_created, vol2] == MetaData.list_volumes()
    Volume.destroy(vol1.name)
    assert [vol2] == MetaData.list_volumes()
    Volume.destroy(vol2.name)
    assert [] == MetaData.list_volumes()
  end

  test "verify volume binding" do
    # use /mnt since this is empty in the basejail by default
    location = "/mnt"
    file = "/mnt/test"
    volume = Volume.create("testvol")

    {:ok, %Container{id: id} = con} =
      TestHelper.create_container("volume_test", %{cmd: ["/usr/bin/touch", file]})

    Jocker.Engine.Container.attach(id)
    :ok = Volume.bind_volume(con, volume, location)
    Jocker.Engine.Container.start(id)

    receive do
      {:container, ^id, {:shutdown, :jail_stopped}} -> :ok
    end

    assert {:ok, %File.Stat{:type => :regular}} = File.stat(Path.join(volume.mountpoint, "test"))
    Volume.destroy(volume.name)
    Container.destroy(id)
  end
end
