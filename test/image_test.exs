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

  @tmp_dockerfile "tmp_dockerfile"
  @tmp_context "./"

  test "building a simple image that generates some text" do
    dockerfile = """
    FROM scratch
    RUN echo "lets test that we receives this!"
    RUN uname
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      quiet: false,
      tag: "websock_img:latest"
    }

    {:ok, conn} = TestHelper.image_build(config)
    frames = TestHelper.receive_frames(conn)
    {finish_msg, build_log} = List.pop_at(frames, -1)

    assert build_log == [
             "OK",
             "Step 1/3 : FROM scratch\n",
             "Step 2/3 : RUN echo \"lets test that we receives this!\"\n",
             "lets test that we receives this!\n",
             "Step 3/3 : RUN uname\n",
             "FreeBSD\n"
           ]

    assert <<"image created with id ", _::binary>> = finish_msg
    Image.destroy("websock_img")
  end

  test "create an image with a 'RUN' instruction" do
    dockerfile = """
    FROM scratch
    RUN echo "lol1" > /root/test_1.txt
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {%Image{layer_id: layer_id}, _messages} =
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

    {%Image{layer_id: layer_id}, _messages} =
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

    {%Image{layer_id: layer_id}, _messages} =
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

    {_image, _messages} =
      TestHelper.build_and_return_image(@tmp_context, @tmp_dockerfile, "test:latest")

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

    {image, _messages} =
      TestHelper.build_and_return_image(@tmp_context, @tmp_dockerfile, "test:latest")

    assert Enum.sort(image.env_vars) == ["TEST2=lool test", "TEST=lol"]
  end

  test "verify that RUN instructions uses the environment variables set earlier in the Dockerfile" do
    dockerfile = """
    FROM scratch
    ENV TEST=testvalue
    RUN printenv
    ENV TEST="a new test value for TEST"
    ENV TEST2=test2value
    RUN printenv
    CMD /bin/ls
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {image, messages} =
      TestHelper.build_and_return_image(@tmp_context, @tmp_dockerfile, "test:latest")

    expected_messages = [
      "Step 1/7 : FROM scratch\n",
      "Step 2/7 : ENV TEST=testvalue\n",
      "Step 3/7 : RUN printenv\n",
      "PWD=/\nTEST=testvalue\n",
      "Step 4/7 : ENV TEST=\"a new test value for TEST\"\n",
      "Step 5/7 : ENV TEST2=test2value\n",
      "Step 6/7 : RUN printenv\n",
      "PWD=/\nTEST=a new test value for TEST\nTEST2=test2value\n",
      "Step 7/7 : CMD /bin/ls\n"
    ]

    assert expected_messages == messages
    assert Enum.sort(image.env_vars) == ["TEST2=test2value", "TEST=a new test value for TEST"]
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

    {%Image{layer_id: layer_id}, _messages} =
      TestHelper.build_and_return_image(context, @tmp_dockerfile, "test:latest")

    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
    assert File.read(Path.join(mountpoint, "root/test_1.txt")) == {:ok, "lol1\n"}
    assert File.read(Path.join(mountpoint, "root/test_2.txt")) == {:ok, "lol2\n"}
    assert MetaData.list_containers() == []
  end

  test "building an image quietly" do
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
    {:ok, pid} = Image.build(context, @tmp_dockerfile, "test:latest", true)
    {_img, messages} = TestHelper.receive_imagebuilder_results(pid, [])

    assert messages == []
  end

  test "try building an image from a invalid Dockerfile" do
    dockerfile = """
    FROM scratch
    RUN echo
      "this should faile because we omitted the '\\' above"
    CMD /usr/bin/uname
    """

    context = create_test_context("test_image_builder_three_layers")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    assert {:error, "error parsing: '  \"this should faile because we omitted the '\\' above\"'"} ==
             Image.build(context, @tmp_dockerfile, "test:latest", true)
  end

  defp create_test_context(name) do
    dataset = Path.join(Config.get("zroot"), name)
    mountpoint = Path.join("/", dataset)
    Jocker.Engine.ZFS.create(dataset)
    {"", 0} = System.cmd("sh", ["-c", "echo 'lol' > #{mountpoint}/test.txt"])
    mountpoint
  end
end
