defmodule VolumeTest do
  use Kleened.Test.ConnCase

  alias Kleened.Core.{MetaData, Container, Volume, Mount}
  alias Kleened.API.Schemas

  @moduletag :capture_log

  test "test filesystem operations when creating and deleting volumes", %{
    api_spec: api_spec
  } do
    %{dataset: dataset, mountpoint: mountpoint} =
      volume = TestHelper.volume_create(api_spec, "test")

    assert {:ok, %File.Stat{:type => :directory}} = File.stat(mountpoint)
    assert {"#{dataset}\n", 0} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
    TestHelper.volume_remove(api_spec, volume.name)
    assert {:error, :enoent} = File.stat(mountpoint)
    assert {"", 1} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
  end
end
