defmodule ImageTest do
  use Kleened.API.ConnCase
  alias Kleened.Core.{Config, Image, MetaData, Layer, Container}
  alias Kleened.API.Schemas
  alias Schemas.WebSocketMessage, as: Message

  @moduletag :capture_log

  setup do
    on_exit(fn ->
      MetaData.list_containers() |> Enum.map(fn %{id: id} -> Container.remove(id) end)
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

    {%Schemas.Image{id: image_id}, _build_id, build_log} = TestHelper.image_valid_build(config)

    assert build_log == [
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
    # Using string instead of boolean in parameter 'quiet'
    assert ["Invalid boolean. Got: string", {1002, %Message{message: "invalid parameters"}}] =
             TestHelper.image_build_raw(%{context: "./", quiet: "lol"})

    # Omitting only necessary parameter 'context'
    assert ["Missing field: context", {1002, %Message{message: "invalid parameters"}}] =
             TestHelper.image_build_raw(%{dockerfile: "Dockerfile"})

    # Using invalid buildargs-input
    assert ["Invalid object. Got: string", {1002, %Message{message: "invalid parameters"}}] =
             TestHelper.image_build_raw(%{context: "./", buildargs: "should-be-JSON"})
  end

  test "create an image with a 'RUN' instruction" do
    dockerfile = """
    FROM scratch
    RUN echo "lol1" > /root/test_1.txt
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {%Schemas.Image{layer_id: layer_id}, _build_id, _build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "/root/test_1.txt")) == {:ok, "lol1\n"}
  end

  test "verify 'WORKDIR' behaviour: Absolute path and auto-creation" do
    dockerfile = """
    FROM scratch
    # Create directory and test RUN-instruction
    WORKDIR /testdir
    RUN pwd
    RUN echo "lol" > testfile

    # Use existing directory and test COPY-instruction
    WORKDIR /home/
    RUN pwd
    COPY test.txt .
    """

    context = create_test_context("test_copy_instruction")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    {%Schemas.Image{layer_id: layer_id}, _build_id, build_log} =
      TestHelper.image_valid_build(config)

    expected_log = [
      "Step 1/7 : FROM scratch\n",
      "Step 2/7 : WORKDIR /testdir\n",
      "Step 3/7 : RUN pwd\n",
      "/testdir\n",
      "Step 4/7 : RUN echo \"lol\" > testfile\n",
      "Step 5/7 : WORKDIR /home/\n",
      "Step 6/7 : RUN pwd\n",
      "/home\n",
      "Step 7/7 : COPY test.txt .\n"
    ]

    assert expected_log == build_log
    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "/testdir/testfile")) == {:ok, "lol\n"}
    assert File.read(Path.join(mountpoint, "/home/test.txt")) == {:ok, "lol\n"}
  end

  test "verify 'WORKDIR' behaviour: Relative path" do
    dockerfile = """
    FROM scratch
    WORKDIR /a
    WORKDIR b
    WORKDIR c
    RUN pwd
    WORKDIR /home
    RUN pwd
    """

    context = create_test_context("test_copy_instruction")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    {_image, _build_id, build_log} = TestHelper.image_valid_build(config)

    expected_log = [
      "Step 1/7 : FROM scratch\n",
      "Step 2/7 : WORKDIR /a\n",
      "Step 3/7 : WORKDIR b\n",
      "Step 4/7 : WORKDIR c\n",
      "Step 5/7 : RUN pwd\n",
      "/a/b/c\n",
      "Step 6/7 : WORKDIR /home\n",
      "Step 7/7 : RUN pwd\n",
      "/home\n"
    ]

    assert expected_log == build_log
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

    {%Schemas.Image{layer_id: layer_id}, _build_id, _build_log} =
      TestHelper.image_valid_build(config)

    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
    assert MetaData.list_containers() == []
  end

  test "create an image with a 'COPY' instruction where <dest> does exist yet" do
    dockerfile = """
    FROM scratch
    COPY test.txt /root/lol/
    """

    context = create_test_context("test_copy_instruction")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    {%Schemas.Image{layer_id: layer_id}, _build_id, _build_log} =
      TestHelper.image_valid_build(config)

    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "root/lol/test.txt")) == {:ok, "lol\n"}
    assert MetaData.list_containers() == []
  end

  test "create an image with a wildcard-expandable 'COPY' instruction" do
    dockerfile = """
    FROM scratch
    COPY *.txt /root/
    """

    context = create_test_context("test_expanded_copy_instruction")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    {%Schemas.Image{layer_id: layer_id}, _build_id, _build_log} =
      TestHelper.image_valid_build(config)

    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
    assert File.read(Path.join(mountpoint, "root/test2.txt")) == {:ok, "lel\n"}
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

    {%Schemas.Image{layer_id: layer_id}, _build_id, _build_log} =
      TestHelper.image_valid_build(config)

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

    {%Schemas.Image{id: image_id}, _build_id, _build_log} =
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

  test "create an image with 'ENV' instructions using basic notations" do
    dockerfile = """
    FROM scratch
    ENV TEST1=lol
    ENV TEST2="testing test"
    ENV TEST3=test\ test
    RUN  printenv
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {image, _build_id, build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    assert List.last(build_log) == "PWD=/\nTEST1=lol\nTEST2=testing test\nTEST3=test test\n"
    assert Enum.sort(image.env) == ["TEST1=lol", "TEST2=testing test", "TEST3=test test"]
  end

  test "create an image with a quoted and escaped ENV-instruction" do
    dockerfile = """
    FROM scratch
    ENV TEST="\\$5\\$2Fun7BK4thgtd4ao\\$j1kidg9P"
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {image, _build_id, _build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    assert Enum.sort(image.env) == ["TEST=$5$2Fun7BK4thgtd4ao$j1kidg9P"]
  end

  test "verify that RUN instructions uses the ENV variables set earlier in the Dockerfile" do
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

    {image, _build_id, build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    expected_build_log = [
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
        "Step 1/4 : FROM scratch\n",
        "Step 2/4 : ARG testvar\n",
        "Step 3/4 : RUN echo \"lol:\$testvar\"\n",
        "#{x}\n",
        "Step 4/4 : RUN echo \"lol:${testvar:-empty}\"\n",
        "#{y}\n"
      ]
    end

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, _build_id, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log.("lol:", "lol:empty") == build_log

    config = Map.put(config, :buildargs, %{"testvar" => "testval"})
    {_image, _build_id, build_log} = TestHelper.image_valid_build(config)

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
        "Step 1/4 : FROM scratch\n",
        "Step 2/4 : ARG testvar1=testval1\n",
        "Step 3/4 : ARG testvar2=\"test val2\"\n",
        "Step 4/4 : RUN echo \"$testvar1:$testvar2\"\n",
        "#{x}\n"
      ]
    end

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, _build_id, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log.("testval1:test val2") == build_log

    config = Map.put(config, :buildargs, %{"testvar1" => "newval1", "testvar2" => "newval2"})
    {_image, _build_id, build_log} = TestHelper.image_valid_build(config)

    assert expected_build_log.("newval1:newval2") == build_log
  end

  test "test precedenice ARG-variable definition: Client vs. Dockerfile" do
    dockerfile = """
    FROM scratch
    USER ${username:-ntpd}
    ARG username
    RUN whoami
    USER $username
    RUN whoami
    """

    expected_build_log = [
      "Step 1/6 : FROM scratch\n",
      "Step 2/6 : USER ${username:-ntpd}\n",
      "Step 3/6 : ARG username\n",
      "Step 4/6 : RUN whoami\n",
      "ntpd\n",
      "Step 5/6 : USER $username\n",
      "Step 6/6 : RUN whoami\n",
      "games\n"
    ]

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest",
      buildargs: %{"username" => "games"}
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    {_image, _build_id, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log
  end

  test "test that ENV-instruction always override an ARG-instruction" do
    dockerfile = """
    FROM scratch
    ARG CONT_IMG_VER
    ENV CONT_IMG_VER=v1.0.0
    RUN echo $CONT_IMG_VER
    """

    expected_build_log = [
      "Step 1/4 : FROM scratch\n",
      "Step 2/4 : ARG CONT_IMG_VER\n",
      "Step 3/4 : ENV CONT_IMG_VER=v1.0.0\n",
      "Step 4/4 : RUN echo $CONT_IMG_VER\n",
      "v1.0.0\n"
    ]

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest",
      buildargs: %{"CONT_IMG_VER" => "v2.0.1"}
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    {_image, _build_id, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log
  end

  test "Test ARG-variable persistence using ENV-variable and CMD environement substitution", %{
    api_spec: api_spec
  } do
    dockerfile = """
    FROM scratch
    ARG CONT_IMG_VER
    ENV CONT_IMG_VER=${CONT_IMG_VER:-v1.0.0}
    CMD echo $CONT_IMG_VER
    """

    expected_build_log = [
      "Step 1/4 : FROM scratch\n",
      "Step 2/4 : ARG CONT_IMG_VER\n",
      "Step 3/4 : ENV CONT_IMG_VER=${CONT_IMG_VER:-v1.0.0}\n",
      "Step 4/4 : CMD echo $CONT_IMG_VER\n"
    ]

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    # Build and run _without_ supplied buildarg
    {image, _build_id, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log

    {container, exec_id} =
      TestHelper.container_start_attached(api_spec, "test-arg2env", %{image: image.id})

    assert TestHelper.collect_container_output(exec_id) == "v1.0.0\n"
    Kleened.Core.Container.remove(container.id)

    # Build and run _with_ supplied buildarg
    config = Map.put(config, :buildargs, %{"CONT_IMG_VER" => "v.2.0.1"})
    {image, _build_id, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log

    {container, exec_id} =
      TestHelper.container_start_attached(api_spec, "test-arg2env", %{image: image.id})

    assert TestHelper.collect_container_output(exec_id) == "v.2.0.1\n"
    Kleened.Core.Container.remove(container.id)
  end

  test "invalid ENV and ARG variable names" do
    dockerfile = """
    FROM scratch
    ARG TEST-VAR="this should fail"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    {error, _build_id, build_log} = TestHelper.image_invalid_build(config)

    assert build_log == [
             "ENV/ARG variable name is invalid on line: ARG TEST-VAR=\"this should fail\""
           ]

    assert error == "failed to process Dockerfile"

    dockerfile = """
    FROM scratch
    ENV TEST-VAR="this should fail"
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    {error, _build_id, build_log} = TestHelper.image_invalid_build(config)

    assert build_log == [
             "ENV/ARG variable name is invalid on line: ENV TEST-VAR=\"this should fail\""
           ]

    assert error == "failed to process Dockerfile"
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
        "Step 1/4 : FROM scratch\n",
        "Step 2/4 : ARG TESTVAR=ntpd\n",
        "Step 3/4 : USER $TESTVAR\n",
        "Step 4/4 : RUN echo \"$(/usr/bin/id)\"\n",
        "#{x}\n"
      ]
    end

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, _build_id, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log.("uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)") == build_log
  end

  test "create ARG-variable and use with COPY instruction" do
    dockerfile = """
    FROM scratch
    ARG TESTVAR="test.txt"
    COPY $TESTVAR /root/
    """

    expected_build_log = [
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

    {%Schemas.Image{layer_id: layer_id}, _build_id, build_log} =
      TestHelper.image_valid_build(config)

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
      "Step 1/4 : FROM scratch\n",
      "Step 2/4 : ARG testvar=should_be_overwritten\n",
      "Step 3/4 : ARG testvar\n",
      "Step 4/4 : RUN echo -n \"empty:$testvar\"\n",
      "empty:"
    ]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, _build_id, build_log} = TestHelper.image_valid_build(config)
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
      "Step 1/4 : FROM scratch\n",
      "Step 2/4 : ARG CONT_IMG_VER\n",
      "Step 3/4 : ENV CONT_IMG_VER=v1.0.0\n",
      "Step 4/4 : RUN echo $CONT_IMG_VER\n",
      "v1.0.0\n"
    ]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, _build_id, build_log} = TestHelper.image_valid_build(config)
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

    {%Schemas.Image{layer_id: layer_id}, _build_id, _build_log} =
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

    {_image, _build_id, build_log} =
      TestHelper.image_valid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile,
        quiet: true,
        tag: "test:latest"
      })

    assert build_log == []
  end

  test "image-build stops prematurely from non-zero exitcode from RUN-instruction" do
    dockerfile = """
    FROM scratch
    RUN ls notexist
    RUN echo "this should not be executed"
    """

    context = create_test_context("test_image_run_nonzero_exitcode")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    {error, _build_id, build_log} =
      TestHelper.image_invalid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile
      })

    assert last_log_entry(build_log) == "executing instruction resulted in non-zero exit code"
    assert error == "image build failed"
  end

  test "image-build stops prematurely from non-zero exitcode that keeps build-container" do
    dockerfile = """
    FROM scratch
    RUN echo "test" > /etc/testing
    RUN ls notexist
    """

    context = create_test_context("test_image_run_nonzero_exitcode")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    {error, build_id, build_log} =
      TestHelper.image_invalid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile,
        quiet: false,
        cleanup: false,
        tag: "test:latest"
      })

    assert last_log_entry(build_log) == "executing instruction resulted in non-zero exit code"
    assert error == "image build failed"

    %Schemas.Container{layer_id: layer_id} =
      Kleened.Core.MetaData.get_container("build_#{build_id}")

    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "/etc/testing")) == {:ok, "test\n"}
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

    {error, _build_id, build_log} =
      TestHelper.image_invalid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile
      })

    assert error == "failed to process Dockerfile"

    assert last_log_entry(build_log) ==
             "invalid instruction:   \"this should faile because we omitted the '\\' above\""
  end

  test "try building an image with an invalid image name in the FROM-instruction" do
    dockerfile = """
    FROM nonexisting
    CMD /bin/ls
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, @tmp_context)

    {error, _build_id, build_log} =
      TestHelper.image_invalid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile
      })

    assert build_log == ["Step 1/2 : FROM nonexisting\n", "image not found"]
    assert error == "image build failed"
  end

  test "try building an image from a invalid Dockerfile (illegal comment)" do
    dockerfile = """
    FROM scratch
    ENV TEST="something" # You cannot make comments like this.
    """

    context = create_test_context("test_image_builder_three_layers")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    {error, _build_id, build_log} =
      TestHelper.image_invalid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    assert error == "image build failed"

    assert build_log == [
             "Step 1/2 : FROM scratch\n",
             "Step 2/2 : ENV TEST=\"something\" # You cannot make comments like this.\n",
             "failed environment substition of: ENV TEST=\"something\" # You cannot make comments like this."
           ]
  end

  test "create base image using a method 'zfs'", %{api_spec: api_spec} do
    config = %{
      method: "zfs",
      zfs_dataset: "zroot/kleene_basejail",
      tag: "FreeBSD:testing-remote"
    }

    frames = TestHelper.image_create(config)
    {{1000, closing_msg}, _rest} = List.pop_at(frames, -1)
    assert %Message{data: _, message: "image created", msg_type: "closing"} = closing_msg

    {_cont, exec_id} =
      TestHelper.container_start_attached(api_spec, "testcont", %{
        image: closing_msg.data,
        cmd: ["/usr/bin/id"],
        jail_param: [],
        user: "root"
      })

    assert_receive {:container, ^exec_id, {:jail_output, jail_output}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}
    assert jail_output == "uid=0(root) gid=0(wheel) groups=0(wheel),5(operator)\n"
  end

  test "create base image using a method 'fetch'", %{api_spec: api_spec} do
    # The "rescue" system does not work as a jail since it needs /etc/master.passwd (and probably other stuff as well). Thus, any bunch of files in a .txz-file could be used to pass this test.
    # Consider making a special test with a real userland that can be filtered out during development? Could be nice with a more realistic test that uses a full userland (and takes some time to extract).
    config = %{
      # method-name should be "url"
      method: "fetch",
      url: "file://./test/data/base_rescue.txz",
      # url: "file://./test/data/base.txz",
      tag: "FreeBSD:testing"
    }

    frames = TestHelper.image_create(config)
    {{1000, closing_msg}, _rest} = List.pop_at(frames, -1)

    assert %Message{data: _, message: "image created", msg_type: "closing"} = closing_msg

    {_cont, exec_id} =
      TestHelper.container_start_attached(api_spec, "testcont", %{
        image: closing_msg.data,
        cmd: ["/bin/id"],
        jail_param: [],
        user: "root"
      })

    assert_receive {:container, ^exec_id, {:jail_output, jail_output}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 1}}}
    assert String.slice(jail_output, 0, 46) == "jail: getpwnam root: No such file or directory"
  end

  defp create_test_context(name) do
    dataset = Path.join(Config.get("zroot"), name)
    mountpoint = Path.join("/", dataset)
    Kleened.Core.ZFS.create(dataset)
    {"", 0} = System.cmd("sh", ["-c", "echo 'lol' > #{mountpoint}/test.txt"])
    {"", 0} = System.cmd("sh", ["-c", "echo 'lel' > #{mountpoint}/test2.txt"])
    mountpoint
  end

  defp last_log_entry(log) do
    [last_log_entry | _] = Enum.reverse(log)
    last_log_entry
  end
end
