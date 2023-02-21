defmodule ImageTest do
  use Kleened.API.ConnCase
  alias Kleened.Core.{Config, Image, MetaData, Layer}
  alias Kleened.API.Schemas

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

    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
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
    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
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

    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    # we cannot check the symbolic link from the host:
    assert File.read(Path.join(mountpoint, "etc/testdir/test.txt")) == {:ok, "lol\n"}
  end

  test "create an image with a 'CMD' instruction", %{api_spec: api_spec} do
    dockerfile = """
    FROM scratch
    CMD  echo -n "lol"
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {%Schemas.Image{id: image_id}, _build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    assert MetaData.list_containers() == []

    config = %{image: image_id}

    {container, exec_id} =
      TestHelper.container_start_attached(api_spec, "test-cmd-instruc", config)

    assert TestHelper.collect_container_output(exec_id) == "lol"
    Kleened.Core.Container.remove(container.id)
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

    assert Enum.sort(image.env) == ["TEST2=lool test", "TEST=lol"]
  end

  test "create an image with a quoted and escaped instruction" do
    dockerfile = """
    FROM scratch
    ENV TEST="\\$5\\$2Fun7BK4thgtd4ao\\$j1kidg9P"
    CMD  /bin/ls
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {image, _build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    assert Enum.sort(image.env) == ["TEST=$5$2Fun7BK4thgtd4ao$j1kidg9P"]
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
    assert Enum.sort(image.env) == ["TEST2=test2value", "TEST=a new test value for TEST"]
  end

  test "create image with ARG-variable without an explicit default value, thus empty string" do
    dockerfile = """
    FROM scratch
    ARG testvar
    RUN echo "lol:$testvar"
    RUN echo "lol:${testvar:-empty}"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_build_log = fn x, y ->
      [
        "OK",
        "Step 1/4 : FROM scratch\n",
        "Step 2/4 : ARG testvar\n",
        "Step 3/4 : RUN echo \"lol:\$testvar\"\n",
        "#{x}\n",
        "Step 4/4 : RUN echo \"lol:${testvar:-empty}\"\n",
        "#{y}\n"
      ]
    end

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log.("lol:", "lol:empty") == build_log

    config = Map.put(config, :buildargs, %{"testvar" => "testval"})
    {_image, build_log} = TestHelper.image_valid_build(config)

    assert expected_build_log.("lol:testval", "lol:testval") == build_log
  end

  test "create image with ARG-variable with default value" do
    dockerfile = """
    FROM scratch
    ARG testvar1=testval1
    ARG testvar2="test val2"
    RUN echo "$testvar1:$testvar2"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_build_log = fn x ->
      [
        "OK",
        "Step 1/4 : FROM scratch\n",
        "Step 2/4 : ARG testvar1=testval1\n",
        "Step 3/4 : ARG testvar2=\"test val2\"\n",
        "Step 4/4 : RUN echo \"$testvar1:$testvar2\"\n",
        "#{x}\n"
      ]
    end

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log.("testval1:test val2") == build_log

    config = Map.put(config, :buildargs, %{"testvar1" => "newval1", "testvar2" => "newval2"})
    {_image, build_log} = TestHelper.image_valid_build(config)

    assert expected_build_log.("newval1:newval2") == build_log
  end

  test "create arg-variable and use with ENV-instruction", %{api_spec: api_spec} do
    dockerfile = """
    FROM scratch
    ARG TESTVAR="use at runtime"
    ENV TESTENVVAR=$TESTVAR
    CMD echo -n $TESTENVVAR
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_build_log = [
      "OK",
      "Step 1/4 : FROM scratch\n",
      "Step 2/4 : ARG TESTVAR=\"use at runtime\"\n",
      "Step 3/4 : ENV TESTENVVAR=$TESTVAR\n",
      "Step 4/4 : CMD echo -n $TESTENVVAR\n"
    ]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {%Schemas.Image{id: image_id}, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log

    config = %{image: image_id}
    {container, exec_id} = TestHelper.container_start_attached(api_spec, "test-arg2env", config)
    assert TestHelper.collect_container_output(exec_id) == "use at runtime"
    Kleened.Core.Container.remove(container.id)
  end

  test "invalid ENV and ARG variable names" do
    dockerfile = """
    FROM scratch
    ARG TEST-VAR="this should fail"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_build_log = [
      "ERROR:ENV/ARG variable name is invalid on line: ARG TEST-VAR=\"this should fail\"",
      "failed to build image"
    ]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    build_log = TestHelper.image_build(config)
    assert expected_build_log == build_log

    dockerfile = """
    FROM scratch
    ENV TEST-VAR="this should fail"
    """

    expected_build_log = [
      "ERROR:ENV/ARG variable name is invalid on line: ENV TEST-VAR=\"this should fail\"",
      "failed to build image"
    ]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    build_log = TestHelper.image_build(config)
    assert expected_build_log == build_log
  end

  test "create arg-variable and use with USER-instruction" do
    dockerfile = """
    FROM scratch
    ARG TESTVAR=ntpd
    USER $TESTVAR
    RUN echo "$(/usr/bin/id)"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_build_log = fn x ->
      [
        "OK",
        "Step 1/4 : FROM scratch\n",
        "Step 2/4 : ARG TESTVAR=ntpd\n",
        "Step 3/4 : USER $TESTVAR\n",
        "Step 4/4 : RUN echo \"$(/usr/bin/id)\"\n",
        "#{x}\n"
      ]
    end

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log.("uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)") == build_log
  end

  test "create ARG-variable and use with COPY instruction" do
    dockerfile = """
    FROM scratch
    ARG TESTVAR="test.txt"
    COPY $TESTVAR /root/
    """

    expected_build_log = [
      "OK",
      "Step 1/3 : FROM scratch\n",
      "Step 2/3 : ARG TESTVAR=\"test.txt\"\n",
      "Step 3/3 : COPY $TESTVAR /root/\n"
    ]

    context = create_test_context("test_arg_with_copy_instruction")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    {%Schemas.Image{layer_id: layer_id}, build_log} = TestHelper.image_valid_build(config)
    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)

    assert expected_build_log == build_log
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
  end

  test "declaring a ARG-variable a second time overrides the first value" do
    dockerfile = """
    FROM scratch
    ARG testvar=should_be_overwritten
    ARG testvar
    RUN echo -n "empty:$testvar"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_build_log = [
      "OK",
      "Step 1/4 : FROM scratch\n",
      "Step 2/4 : ARG testvar=should_be_overwritten\n",
      "Step 3/4 : ARG testvar\n",
      "Step 4/4 : RUN echo -n \"empty:$testvar\"\n",
      "empty:"
    ]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log
  end

  test "ENV instructions takes precedence over ARG-instructions" do
    dockerfile = """
    FROM scratch
    ARG CONT_IMG_VER
    ENV CONT_IMG_VER=v1.0.0
    RUN echo $CONT_IMG_VER
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_build_log = [
      "OK",
      "Step 1/4 : FROM scratch\n",
      "Step 2/4 : ARG CONT_IMG_VER\n",
      "Step 3/4 : ENV CONT_IMG_VER=v1.0.0\n",
      "Step 4/4 : RUN echo $CONT_IMG_VER\n",
      "v1.0.0\n"
    ]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log
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

    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
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

  test "building an image that stops prematurely from non-zero exitcode from RUN-instruction" do
    dockerfile = """
    FROM scratch
    RUN ls notexist
    RUN echo "this should not be executed"
    """

    context = create_test_context("test_image_run_nonzero_exitcode")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    assert "RUN ls notexist" ==
             TestHelper.image_invalid_build(%{
               context: context,
               dockerfile: @tmp_dockerfile,
               quiet: false,
               tag: "test:latest"
             })
  end

  test "try building an image from a invalid Dockerfile (no linebreak)" do
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
             "ERROR:invalid instruction:   \"this should faile because we omitted the '\\' above\"",
             "failed to build image"
           ]
  end

  test "try building an image from a invalid Dockerfile (illegal comment)" do
    dockerfile = """
    FROM scratch
    ENV TEST="something" # You cannot make comments like this.
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
             "OK",
             "Step 1/2 : FROM scratch\n",
             "Step 2/2 : ENV TEST=\"something\" # You cannot make comments like this.\n",
             "image build failed at: failed environment substition of: ENV TEST=\"something\" # You cannot make comments like this."
           ]
  end

  test "try to build a image with invalid buildargs-input" do
    dockerfile = """
    FROM scratch
    CMD /usr/bin/uname
    """

    context = create_test_context("test_image_builder_three_layers")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      buildargs: %{},
      tag: "test:latest"
    }

    {_, build_log} = TestHelper.image_valid_build(config)

    assert build_log == [
             "OK",
             "Step 1/2 : FROM scratch\n",
             "Step 2/2 : CMD /usr/bin/uname\n"
           ]

    assert TestHelper.image_build_raw(%{config | buildargs: "should-be-JSON"}) ==
             {:error,
              "could not decode 'buildargs' JSON content: %Jason.DecodeError{data: \"should-be-JSON\", position: 0, token: nil}"}
  end

  defp create_test_context(name) do
    dataset = Path.join(Config.get("zroot"), name)
    mountpoint = Path.join("/", dataset)
    Kleened.Core.ZFS.create(dataset)
    {"", 0} = System.cmd("sh", ["-c", "echo 'lol' > #{mountpoint}/test.txt"])
    mountpoint
  end
end
