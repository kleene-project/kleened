defmodule VolumeTest do
  use Kleened.Test.ConnCase
  require Logger

  alias Kleened.Core.{MetaData, Container, Volume, Mount}
  alias Kleened.API.Schemas

  @moduletag :capture_log

  setup do
    on_exit(fn ->
      Kleened.Core.MetaData.list_volumes()
      |> Enum.map(&Volume.destroy(&1.name))
    end)

    :ok
  end

  test "test filesystem operations when creating and deleting volumes", %{
    api_spec: api_spec
  } do
    %{dataset: dataset, mountpoint: mountpoint} =
      volume = TestHelper.volume_create(api_spec, "test")

    assert {:ok, %File.Stat{:type => :directory}} = File.stat(mountpoint)
    assert {"#{dataset}\n", 0} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
    TestHelper.volume_destroy(api_spec, volume.name)
    assert {:error, :enoent} = File.stat(mountpoint)
    assert {"", 1} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
  end

  test "list when there are zero volumes", %{
    api_spec: api_spec
  } do
    assert [] == TestHelper.volume_list(api_spec)
  end

  test "list with one volume then with zero volumes", %{
    api_spec: api_spec
  } do
    volume = TestHelper.volume_create(api_spec, "test-one-zero")
    response = TestHelper.volume_list(api_spec)
    assert [volume] == response
    TestHelper.volume_destroy(api_spec, volume.name)
    response = TestHelper.volume_list(api_spec)
    assert [] == response
  end

  test "inspect a volume", %{
    api_spec: api_spec
  } do
    volume = TestHelper.volume_create(api_spec, "test-inspect")
    response = TestHelper.volume_inspect("test-notexist")
    assert response.status == 404
    response = TestHelper.volume_inspect(volume.name)
    assert response.status == 200
    result = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert %{volume: %{name: "test-inspect"}} = result
    assert_schema(result, "VolumeInspect", api_spec)
  end

  test "list with two volumes then with one volume", %{
    api_spec: api_spec
  } do
    volume1 = TestHelper.volume_create(api_spec, "test-two-one1")
    volume2 = TestHelper.volume_create(api_spec, "test-two-one2")
    assert [volume2, volume1] == TestHelper.volume_list(api_spec)
    TestHelper.volume_destroy(api_spec, volume2.name)
    assert [volume1] == TestHelper.volume_list(api_spec)
    TestHelper.volume_destroy(api_spec, volume1.name)
  end

  test "prune volumes", %{api_spec: api_spec} do
    # use /mnt since this is empty in the basejail by default
    destination = "/mnt"
    volume1 = Volume.create("prunevol1")
    _volume2 = Volume.create("prunevol2")

    %{id: id} =
      TestHelper.container_create(api_spec, %{name: "volume_test", cmd: ["/bin/sleep", "10"]})

    container = MetaData.get_container(id)

    mount_config = %Schemas.MountPointConfig{
      type: "volume",
      source: volume1.name,
      destination: destination
    }

    {:ok, _mount} = Mount.create(container, mount_config)
    assert ["prunevol2"] = TestHelper.volume_prune(api_spec)
    assert [%{name: "prunevol1"}] = TestHelper.volume_list(api_spec)
    Container.remove(id)
  end
end
