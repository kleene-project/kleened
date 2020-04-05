defmodule MetaDataTest do
  use ExUnit.Case
  import Jocker.MetaData

  # test "starting mnesia" do
  #  Jocker.ZFS.clear_zroot()
  #  result = Jocker.MetaData.start_link()
  #  assert {:ok, pid} = result
  #  GenServer.stop(pid)
  # end

  setup_all do
    Jocker.MetaData.start_link()
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
    assert image1 = get_image(image(img1, :id))
    assert image1 = get_image("test:oldest")
    assert image2 = get_image("test")
    assert [img2, img1] == list_images()
  end

  test "list containers" do
    add_container(container(id: "1337", name: "test1", created: now()))
    add_container(container(id: "1338", name: "test2", created: now()))
    add_container(container(id: "1339", name: "test3", created: now()))
    containers = list_containers()

    assert [
             container(id: "1339"),
             container(id: "1338"),
             container(id: "1337")
           ] = containers
  end

  test "list running containers" do
    add_container(container(id: "1", name: "test1", created: now()))
    add_container(container(id: "2", name: "test2", running: true, created: now()))
    containers = list_running_containers()

    assert [container(id: "2")] = containers
  end

  defp now(), do: :erlang.timestamp()
end
