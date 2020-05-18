defmodule MetaDataTest do
  use ExUnit.Case
  require Jocker.Engine.Config
  import Jocker.Engine.MetaData
  import Jocker.Engine.Records

  setup_all do
    :ok = Application.stop(:jocker)
    :ok
  end

  setup do
    File.rm(dbfile())
    start_link(file: dbfile())
    :ok
  end

  test "test db creation" do
    assert db_exists?()
    stop()
    File.rm(dbfile())
    start_link(file: dbfile())
    assert db_exists?()
  end

  test "adding and getting layers" do
    layer1 = layer(id: "lol", dataset: "tank/test", mountpoint: "/tank/test/")
    layer2 = layer(layer1, snapshot: "/tank/test@testing")
    add_layer(layer1)
    assert layer1 = get_layer("lol")
    add_layer(layer2)
    assert layer2 = get_layer("lol")
    assert :not_found == get_layer("notexist")
  end

  test "adding and getting images" do
    img1 = image(id: "lol", name: "test", tag: "oldest", created: now())
    img2 = image(id: "lel", name: "test", tag: "latest", created: now())
    add_image(img1)
    add_image(img2)
    assert img1 == get_image(image(img1, :id))
    assert img1 == get_image("test:oldest")
    assert img2 == get_image("test")
    assert [img2, img1] == list_images()

    # Test that name/tag will be removed from existing image if a new image is added with conflicting nametag
    img3 = image(id: "lel2", name: "test", tag: "latest", created: now())
    img2_nametag_removed = image(img2, name: "", tag: "")
    add_image(img3)
    assert img2_nametag_removed == get_image("lel")
  end

  test "empty nametags are avoided in overwrite logic" do
    img1 = image(id: "lol1", name: "", tag: "", created: now())
    img2 = image(id: "lol2", name: "", tag: "", created: now())
    img3 = image(id: "lol3", name: "", tag: "", created: now())
    add_image(img1)
    add_image(img2)
    add_image(img3)
    assert [img3, img2, img1] == list_images()
  end

  test "fetching images that is not there" do
    assert [] = list_images()
    img1 = image(id: "lol", name: "test", tag: "oldest", created: now())
    img2 = image(id: "lel", name: "test", tag: "latest", created: now())
    add_image(img1)
    add_image(img2)
    assert :not_found = get_image("not_here")
    assert :not_found = get_image("not_here:either")
  end

  test "get containers" do
    add_container(container(id: "1337", name: "test1", created: now()))
    add_container(container(id: "1338", name: "1337", created: now()))
    add_container(container(id: "1339", name: "1337", created: now()))
    assert container(id: "1337") = get_container("1337")
    assert container(id: "1337") = get_container("test1")
    assert :not_found == get_container("lol")
  end

  test "list all containers" do
    add_container(container(id: "1337", name: "test1", created: now()))
    add_container(container(id: "1338", name: "test2", created: now()))
    add_container(container(id: "1339", name: "test3", created: now()))
    containers = list_containers(all: true)

    assert [
             container(id: "1339"),
             container(id: "1338"),
             container(id: "1337")
           ] = containers
  end

  test "list running containers" do
    add_container(container(id: "1", name: "test1", created: now()))
    add_container(container(id: "2", name: "test2", running: true, created: now()))
    containers = list_containers()
    containers2 = list_containers(all: false)

    assert [container(id: "2")] = containers
    assert containers == containers2
  end

  defp dbfile() do
    Jocker.Engine.Config.metadata_db()
  end

  defp db_exists?() do
    case File.stat(dbfile()) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp now() do
    :timer.sleep(10)
    DateTime.to_iso8601(DateTime.utc_now())
  end
end
