defmodule ImageTest do
  use ExUnit.Case
  require Jocker.Config
  import Jocker.Records

  setup_all do
    Jocker.ZFS.clear_zroot()
  end

  setup do
    start_supervised(Jocker.MetaData)
    start_supervised(Jocker.Layer)
    start_supervised({Jocker.Network, [{"10.13.37.1", "10.13.37.255"}, "jocker0"]})
    start_supervised(Jocker.ContainerPool)
    :ok
  end

  test "create an image with a 'RUN' instruction" do
    file_path = "/root/test_1.txt"

    instructions = [
      from: "base",
      run: ["/bin/sh", "-c", "echo 'lol1' > " <> file_path]
    ]

    image(layer: layer(mountpoint: mountpoint)) = Jocker.Image.create_image(instructions)
    assert File.read(Path.join(mountpoint, file_path)) == {:ok, "lol1\n"}
  end

  test "create an image with a 'COPY' instruction" do
    instructions = [
      from: "base",
      copy: ["test.txt", "/root/"]
    ]

    context = create_test_context("test_copy_instruction")
    image(layer: layer(mountpoint: mountpoint)) = Jocker.Image.create_image(instructions, context)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
  end

  test "create an image using three RUN/COPY instructions" do
    instructions = [
      from: "base",
      copy: ["test.txt", "/root/"],
      run: ["/bin/sh", "-c", "echo 'lol1' > /root/test_1.txt"],
      run: ["/bin/sh", "-c", "echo 'lol2' > /root/test_2.txt"]
    ]

    context = create_test_context("test_image_builder_three_layers")
    image(layer: layer(mountpoint: mountpoint)) = Jocker.Image.create_image(instructions, context)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
    assert File.read(Path.join(mountpoint, "root/test_1.txt")) == {:ok, "lol1\n"}
    assert File.read(Path.join(mountpoint, "root/test_2.txt")) == {:ok, "lol2\n"}
  end

  defp create_test_context(name) do
    dataset = Path.join(Jocker.Config.zroot(), name)
    mountpoint = Path.join("/", dataset)
    Jocker.ZFS.create(dataset)
    {"", 0} = System.cmd("sh", ["-c", "echo 'lol' > #{mountpoint}/test.txt"])
    mountpoint
  end
end
