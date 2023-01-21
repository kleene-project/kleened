defmodule ImageTest do
  use Jocker.API.ConnCase
  alias Jocker.Engine.{Config, Image, MetaData, Layer}
  alias Jocker.API.Schemas

  @moduletag :capture_log

  setup do
    on_exit(fn ->
      MetaData.list_images() |> Enum.map(fn %Schemas.Image{id: id} -> Image.destroy(id) end)
    end)

    :ok
  end

  @tmp_dockerfile "tmp_dockerfile"
  @tmp_context "./"

  test "building a simple image that generates some text", %{api_spec: api_spec} do
    dockerfile = """
    FROM scratch
    RUN echo "lets test that we receives this!"
    RUN uname
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "websock_img:latest"
    }

    {%Schemas.Image{id: image_id}, build_log} = TestHelper.image_valid_build(config)

    assert build_log == [
             "OK",
             "Step 1/3 : FROM scratch\n",
             "Step 2/3 : RUN echo \"lets test that we receives this!\"\n",
             "lets test that we receives this!\n",
             "Step 3/3 : RUN uname\n",
             "FreeBSD\n"
           ]

    [%{id: ^image_id}] = TestHelper.image_list(api_spec)
    assert MetaData.list_containers() == []
    assert %{id: "websock_img"} == TestHelper.image_destroy(api_spec, "websock_img")

    assert %{message: "Error: No such image: websock_img\n"} ==
             TestHelper.image_destroy(api_spec, "websock_img")

    assert TestHelper.image_list(api_spec) == []
  end

  test "parsing some invalid input to the image builder" do
    dockerfile = """
    FROM scratch
    RUN echo "lets test that we receives this!"
    RUN uname
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "websock_img:latest",
      quiet: "lol"
    }

    assert {:error, "invalid value to argument 'quiet'"} == TestHelper.image_build(config)

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      quiet: false
    }

    assert {:error, "missing argument tag"} == TestHelper.image_build(config)
  end

  test "create an image with a 'RUN' instruction" do
    dockerfile = """
    FROM scratch
    RUN echo "lol1" > /root/test_1.txt
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {%Schemas.Image{layer_id: layer_id}, _build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "/root/test_1.txt")) == {:ok, "lol1\n"}
  end

  test "create an image with a 'COPY' instruction" do
    dockerfile = """
    FROM scratch
    COPY test.txt /root/
    """

    context = create_test_context("test_copy_instruction")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    {%Schemas.Image{layer_id: layer_id}, _build_log} = TestHelper.image_valid_build(config)
    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
    assert MetaData.list_containers() == []
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

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    {%Schemas.Image{layer_id: layer_id}, _build_log} = TestHelper.image_valid_build(config)

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

    {%Schemas.Image{}, _build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

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

    {image, _build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

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

    {image, build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    expected_build_log = [
      "OK",
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

    assert expected_build_log == build_log
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

    {%Schemas.Image{layer_id: layer_id}, _build_log} =
      TestHelper.image_valid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

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

    {_image, build_log} =
      TestHelper.image_valid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile,
        quiet: true,
        tag: "test:latest"
      })

    assert build_log == ["OK"]
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

    build_log =
      TestHelper.image_build(%{
        context: context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    assert build_log == [
             "ERROR:error parsing: '  \"this should faile because we omitted the '\\' above\"'",
             "failed to build image"
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
