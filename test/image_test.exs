defmodule ImageTest do
  use ExUnit.Case
  alias Jocker.Engine.{Config, Image, MetaData, Layer}

  @moduletag :capture_log

  @tmp_dockerfile "tmp_dockerfile"
  @tmp_context "./"

  setup do
    on_exit(fn ->
      MetaData.list_images() |> Enum.map(fn %Image{id: id} -> Image.destroy(id) end)
    end)

    :ok
  end

  test "create an image with a 'RUN' instruction" do
    dockerfile = """
    FROM scratch
    RUN echo "lol1" > /root/test_1.txt
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    %Image{layer_id: layer_id} =
      TestHelper.build_and_return_image(@tmp_context, @tmp_dockerfile, "test:latest")

    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "/root/test_1.txt")) == {:ok, "lol1\n"}
    assert MetaData.list_containers() == []
  end

  test "create an image with a 'COPY' instruction" do
    dockerfile = """
    FROM scratch
    COPY test.txt /root/
    """

    context = create_test_context("test_copy_instruction")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    %Image{layer_id: layer_id} =
      TestHelper.build_and_return_image(context, @tmp_dockerfile, "test:latest")

    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
    assert [] == MetaData.list_containers()
  end

  test "create an image with a 'COPY' instruction using symlinks" do
    dockerfile = """
    FROM scratch
    RUN mkdir /etc/testdir
    RUN ln -s /etc/testdir /etc/symbolic_testdir
    COPY test.txt /etc/symbolic_testdir/
    """

    context = create_test_context("test_copy_instruction_symbolic")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    %Image{layer_id: layer_id} =
      TestHelper.build_and_return_image(context, @tmp_dockerfile, "test:latest")

    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)
    # we cannot check the symbolic link from the host:
    assert File.read(Path.join(mountpoint, "etc/testdir/test.txt")) == {:ok, "lol\n"}
  end

  test "create an image with a 'CMD' instruction" do
    dockerfile = """
    FROM scratch
    CMD  /bin/sleep 10
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    _image = TestHelper.build_and_return_image(@tmp_context, @tmp_dockerfile, "test:latest")
    assert MetaData.list_containers() == []
  end

  test "create an image with 'ENV' instructions" do
    dockerfile = """
    FROM scratch
    ENV TEST=lol
    ENV TEST2="lool test"
    CMD  /bin/ls
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    image = TestHelper.build_and_return_image(@tmp_context, @tmp_dockerfile, "test:latest")
    assert image.env_vars == ["TEST2=lool test", "TEST=lol"]
  end

  test "create an image using three RUN/COPY instructions" do
    dockerfile = """
    FROM scratch
    COPY test.txt /root/
    RUN echo 'lol1' > /root/test_1.txt
    RUN echo 'lol2' > /root/test_2.txt
    """

    context = create_test_context("test_image_builder_three_layers")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    %Image{layer_id: layer_id} =
      TestHelper.build_and_return_image(context, @tmp_dockerfile, "test:latest")

    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
    assert File.read(Path.join(mountpoint, "root/test_1.txt")) == {:ok, "lol1\n"}
    assert File.read(Path.join(mountpoint, "root/test_2.txt")) == {:ok, "lol2\n"}
    assert MetaData.list_containers() == []
  end

  test "receiving of status messages during build" do
    dockerfile = """
    FROM scratch
    COPY test.txt /root/
    RUN echo \
      "this should be relayed back to the parent process"
    USER ntpd
    CMD /etc/rc
    """

    context = create_test_context("test_image_builder_three_layers")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)
    {:ok, pid} = Image.build(context, @tmp_dockerfile, "test:latest", false)
    {_img, messages} = TestHelper.receive_imagebuilder_results(pid, [])

    assert messages == [
             "Step 1/5 : FROM scratch\n",
             "Step 2/5 : COPY test.txt /root/\n",
             "Step 3/5 : RUN echo   \"this should be relayed back to the parent process\"\n",
             "this should be relayed back to the parent process\n",
             "Step 4/5 : USER ntpd\n",
             "Step 5/5 : CMD /etc/rc\n"
           ]
  end

  defp create_test_context(name) do
    dataset = Path.join(Config.get("zroot"), name)
    mountpoint = Path.join("/", dataset)
    Jocker.Engine.ZFS.create(dataset)
    {"", 0} = System.cmd("sh", ["-c", "echo 'lol' > #{mountpoint}/test.txt"])
    mountpoint
  end
end
