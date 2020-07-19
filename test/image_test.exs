defmodule ImageTest do
  use ExUnit.Case
  alias Jocker.Engine.Config
  alias Jocker.Engine.Image
  alias Jocker.Engine.MetaData
  import Jocker.Engine.Records

  @moduletag :capture_log

  setup_all do
    Application.stop(:jocker)
    start_supervised(Config)
    TestUtils.clear_zroot()
    :ok
  end

  setup do
    start_supervised(Jocker.Engine.MetaData)
    start_supervised(Jocker.Engine.Layer)
    start_supervised(Jocker.Engine.Network)

    start_supervised(
      {DynamicSupervisor, name: Jocker.Engine.ContainerPool, strategy: :one_for_one}
    )

    on_exit(fn -> stop_and_delete_db() end)
    :ok
  end

  test "create an image with a 'RUN' instruction" do
    file_path = "/root/test_1.txt"

    instructions = [
      from: "base",
      run: ["/bin/sh", "-c", "echo 'lol1' > " <> file_path]
    ]

    {:ok, image(layer_id: layer_id)} = Image.create_image(instructions)
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, file_path)) == {:ok, "lol1\n"}
    assert [] == MetaData.list_containers(all: true)
  end

  test "create an image with a 'COPY' instruction" do
    instructions = [
      from: "base",
      copy: ["test.txt", "/root/"]
    ]

    context = create_test_context("test_copy_instruction")
    {:ok, image(layer_id: layer_id)} = Image.create_image(instructions, context)
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
    assert [] == MetaData.list_containers(all: true)
  end

  test "create an image with a 'COPY' instruction using symlinks" do
    instructions = [
      from: "base",
      run: ["bin/sh", "-c", "mkdir /etc/testdir"],
      run: ["bin/sh", "-c", "ln -s /etc/testdir /etc/symbolic_testdir"],
      copy: ["test.txt", "/etc/symbolic_testdir/"]
    ]

    context = create_test_context("test_copy_instruction_symbolic")
    {:ok, image(layer_id: layer_id)} = Image.create_image(instructions, context)
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    # we cannot check the symbolic link from the host:
    assert File.read(Path.join(mountpoint, "etc/testdir/test.txt")) == {:ok, "lol\n"}
  end

  test "create an image with a 'CMD' instruction" do
    instructions = [
      from: "base",
      cmd: ["/bin/sleep", "10"]
    ]

    {:ok, _image} = Image.create_image(instructions)
    assert [] == MetaData.list_containers(all: true)
  end

  test "create an image using three RUN/COPY instructions" do
    # FIXME ! This fails and it looks like the container-process is being restarted several times.
    instructions = [
      from: "base",
      copy: ["test.txt", "/root/"],
      run: ["/bin/sh", "-c", "echo 'lol1' > /root/test_1.txt"],
      run: ["/bin/sh", "-c", "echo 'lol2' > /root/test_2.txt"]
    ]

    context = create_test_context("test_image_builder_three_layers")
    {:ok, image(layer_id: layer_id)} = Image.create_image(instructions, context)
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
    assert File.read(Path.join(mountpoint, "root/test_1.txt")) == {:ok, "lol1\n"}
    assert File.read(Path.join(mountpoint, "root/test_2.txt")) == {:ok, "lol2\n"}
    assert [] == MetaData.list_containers(all: true)
  end

  defp create_test_context(name) do
    dataset = Path.join(Config.get(:zroot), name)
    mountpoint = Path.join("/", dataset)
    Jocker.Engine.ZFS.create(dataset)
    {"", 0} = System.cmd("sh", ["-c", "echo 'lol' > #{mountpoint}/test.txt"])
    mountpoint
  end

  defp stop_and_delete_db() do
    # Agent.stop(Jocker.Engine.MetaData)
    File.rm(Config.get(:metadata_db))
  end
end
