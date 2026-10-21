defmodule VolumeTest do
  use Kleened.Test.ConnCase

  alias Kleened.Core.{MetaData, Container, Volume, Mount}
  alias Kleened.API.Schemas
  alias Kleened.API.Router

  @opts Router.init([])

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

  test "create volumes from a list with per-item results", %{api_spec: api_spec} do
    TestHelper.volume_create(api_spec, "batchvol")

    response =
      conn(
        :post,
        "/volumes/create",
        Jason.encode!([
          %{name: "batchvol"},
          %{name: "batchvol2"},
          %{name: "batchvol"}
        ])
      )
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert response.status == 201
    results = Jason.decode!(response.resp_body)
    assert length(results) == 3
    # existing volume returned as a success item (skip-if-exists)
    assert %{"name" => "batchvol", "dataset" => _, "mountpoint" => _} = Enum.at(results, 0)
    assert %{"name" => "batchvol2", "dataset" => _} = Enum.at(results, 1)
    # duplicates ALSO succeed — Volume.create/1 returns the existing volume
    assert %{"name" => "batchvol", "dataset" => _} = Enum.at(results, 2)
  end
end
