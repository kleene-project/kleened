defmodule MetaDataTest do
  use ExUnit.Case
  import Jocker.Engine.MetaData
  import Jocker.Engine.Records

  setup_all do
    Jocker.Engine.MetaData.start_link([])
    :ok
  end

  setup do
    on_exit(fn -> clear_tables() end)
  end

  test "fetching stuff that is empty/not there" do
    assert [] = list_images()
    img1 = image(id: "lol", name: "test", tag: "oldest", created: now())
    img2 = image(id: "lel", name: "test", tag: "latest", created: now())
    add_image(img1)
    add_image(img2)
    assert :not_found = get_image("not_here")
    assert :not_found = get_image("not_here:either")
    assert [] = list_containers()
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
    img2_nametag_removed = image(img2, name: :none, tag: :none)
    add_image(img3)
    assert img2_nametag_removed == get_image("lel")
  end

  test "adding and getting layers" do
    layer1 = layer(id: "lol", dataset: "tank/test", mountpoint: "/tank/test/")
    layer2 = layer(layer1, snapshot: "/tank/test@testing")
    add_layer(layer1)
    assert layer1 = get_layer("lol")
    add_layer(layer2)
    assert layer2 = get_layer("lol")
  end

  test "get containers" do
    add_container(container(id: "1337", name: "test1", created: now()))
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

  defp now(), do: :erlang.timestamp()
end
