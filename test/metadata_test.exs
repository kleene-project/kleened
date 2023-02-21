defmodule MetaDataTest do
  use ExUnit.Case
  alias Kleened.Engine.{Config, Volume.Mount, Layer}
  alias Kleened.API.Schemas
  import Kleened.Engine.MetaData
  import TestHelper, only: [now: 0]

  @moduletag :capture_log

  test "adding, listing and removing networks" do
    host_network = get_network("host")
    assert [host_network] == list_networks(:include_host)
    assert [] == list_networks(:exclude_host)

    network1 = %Schemas.Network{id: "test_id1", name: "testname1"}
    network2 = %Schemas.Network{id: "id2_test", name: "testname2"}
    assert :ok = add_network(network1)
    assert [network1] == list_networks(:exclude_host)
    assert network1 == get_network("test_id1")
    assert network1 == get_network("tes")
    assert :ok = add_network(network2)
    assert [network1, network2] == list_networks(:exclude_host)
    remove_network("test_id1")
    assert [host_network, network2] == list_networks(:include_host)
    remove_network("id2_test")
  end

  test "adding and getting layers" do
    layer1 = %Layer{id: "lol", dataset: "tank/test", mountpoint: "/tank/test/"}
    layer2 = %Layer{layer1 | snapshot: "/tank/test@testing"}
    add_layer(layer1)
    assert layer1 == get_layer("lol")
    add_layer(layer2)
    assert layer2 == get_layer("lol")
    assert :not_found == get_layer("notexist")
    remove_layer("lol")
    assert :not_found == get_layer("lol")
  end

  test "adding and getting images" do
    img1 = %Schemas.Image{id: "lol", name: "test", tag: "oldest", created: now()}
    img2 = %Schemas.Image{id: "lel", name: "test", tag: "latest", created: now()}
    add_image(img1)
    add_image(img2)
    assert img1 == get_image(img1.id)
    assert img1 == get_image("test:oldest")
    assert img2 == get_image("test")
    assert [img2, img1] == list_images()

    # Test that name/tag will be removed from existing image if a new image is added with conflicting nametag
    img3 = %Schemas.Image{id: "lel2", name: "test", tag: "latest", created: now()}
    img2_nametag_removed = %{img2 | name: "", tag: ""}
    add_image(img3)
    assert img2_nametag_removed == get_image("lel")
    delete_image("lol")
    delete_image("lel")
    delete_image("lel2")
    assert [] == list_images()
  end

  test "empty nametags are avoided in overwrite logic" do
    img1 = %Schemas.Image{id: "lol1", name: "", tag: "", created: now()}
    img2 = %Schemas.Image{id: "lol2", name: "", tag: "", created: now()}
    img3 = %Schemas.Image{id: "lol3", name: "", tag: "", created: now()}
    add_image(img1)
    add_image(img2)
    add_image(img3)
    assert [img3, img2, img1] == list_images()
    delete_image("lol1")
    delete_image("lol2")
    delete_image("lol3")
  end

  test "fetching images that is not there" do
    assert [] = list_images()
    img1 = %Schemas.Image{id: "lol", name: "test", tag: "oldest", created: now()}
    add_image(img1)
    assert [img1] == list_images()
    assert :not_found = get_image("not_here")
    assert :not_found = get_image("not_here:either")
    delete_image("lol")
  end

  test "add, get and remove containers" do
    add_container(%Schemas.Container{id: "1337", name: "test1", created: now()})
    add_container(%Schemas.Container{id: "1338", name: "1337", created: now()})
    add_container(%Schemas.Container{id: "1339", name: "1337", created: now()})
    assert %Schemas.Container{id: "1337"} = get_container("1337")
    assert %Schemas.Container{id: "1337"} = get_container("test1")
    assert :not_found == get_container("lol")
    delete_container("1338")
    assert :not_found == get_container("1338")
    delete_container("1337")
    delete_container("1339")
    assert [] == list_containers()
  end

  test "list all containers" do
    add_image(%Schemas.Image{id: "lol", created: now()})
    add_image(%Schemas.Image{id: "lel", name: "test", tag: "latest", created: now()})
    add_container(%Schemas.Container{id: "1337", image_id: "lol", name: "test1", created: now()})
    add_container(%Schemas.Container{id: "1338", image_id: "lel", name: "test2", created: now()})
    add_container(%Schemas.Container{id: "1339", image_id: "base", name: "test3", created: now()})
    containers = list_containers()

    assert [
             %{id: "1339", image_id: "base", name: "test3"},
             %{id: "1338", image_id: "lel", name: "test2"},
             %{id: "1337", image_id: "lol", name: "test1"}
           ] = containers

    delete_image("lol")
    delete_image("lel")
    delete_container("1337")
    delete_container("1338")
    delete_container("1339")
    assert [] == list_containers()
  end

  test "adding, listing, and removing volumes" do
    [] = list_volumes()

    vol1 = %Schemas.Volume{
      name: "test1",
      dataset: "dataset/location",
      mountpoint: "mountpoint/location",
      created: now()
    }

    vol1_modified = %Schemas.Volume{vol1 | dataset: "dataset/new_location"}

    vol2 = %Schemas.Volume{
      name: "test2",
      dataset: "dataset/location",
      mountpoint: "mountpoint/location",
      created: now()
    }

    add_volume(vol1)
    assert vol1 == get_volume("test1")
    assert [vol1] == list_volumes()
    add_volume(vol2)
    assert [vol2, vol1] == list_volumes()
    add_volume(vol1_modified)
    assert [vol2, vol1_modified] == list_volumes()
    :ok = remove_volume(vol1)
    assert [vol2] == list_volumes()
    :ok = remove_volume(vol2)
    assert [] == list_volumes()
  end

  test "adding and listing mounts" do
    vol_name = "testvol"

    vol = %Schemas.Volume{
      name: vol_name,
      dataset: "dataset/location",
      mountpoint: "mountpoint/location",
      created: now()
    }

    assert [] == list_mounts(vol)

    mnt1 = %Mount{
      container_id: "contestid",
      volume_name: vol_name,
      location: "location1",
      read_only: false
    }

    mnt2 = %Mount{mnt1 | read_only: true}
    mnt3 = %Mount{volume_name: "some_other_name"}

    add_mount(mnt1)
    assert [mnt1] == list_mounts(vol)
    add_mount(mnt2)
    assert [mnt1, mnt2] == list_mounts(vol)
    add_mount(mnt3)
    assert [mnt1, mnt2] == list_mounts(vol)

    remove_mounts(vol)
    assert [] == list_mounts(vol)
  end

  test "test db creation" do
    db_file = dbfile()
    assert file_exists?(db_file)
    Application.stop(:kleened)
    File.rm(db_file)
    assert not file_exists?(db_file)
    Application.start(:kleened)
    assert file_exists?(db_file)
  end

  defp dbfile() do
    Config.get("metadata_db")
  end

  defp file_exists?(file_path) do
    case File.stat(file_path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
