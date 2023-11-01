defmodule ImageTest do
  use Kleened.API.ConnCase
  alias Kleened.Core.{Config, MetaData, Layer, Container, ZFS, OS}
  alias Kleened.API.Schemas
  alias Schemas.WebSocketMessage, as: Message

  require Logger
  @moduletag :capture_log

  setup do
    on_exit(fn ->
      Logger.info("Cleaning up after test...")
      MetaData.list_containers() |> Enum.map(fn %{id: id} -> Container.remove(id) end)

      MetaData.list_images()
      |> Enum.filter(fn %Schemas.Image{id: id} -> id != "base" end)
      |> Enum.map(fn %Schemas.Image{id: id} -> Kleened.Core.Image.destroy(id) end)
    end)

    :ok
  end

  @tmp_dockerfile "tmp_dockerfile"
  @tmp_context "./"

  test "building a simple image that generates some text", %{api_spec: api_spec} do
    dockerfile = """
    FROM FreeBSD:testing
    RUN echo "lets test that we receive this!"
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
             "lets test that we receive this!\n",
             "FreeBSD\n"
           ]

    [%{id: ^image_id}, %{id: "base"}] = TestHelper.image_list(api_spec)
    assert %{id: "websock_img"} == TestHelper.image_destroy(api_spec, "websock_img")

    assert %{message: "Error: No such image: websock_img\n"} ==
             TestHelper.image_destroy(api_spec, "websock_img")

    assert [%{id: "base"}] = TestHelper.image_list(api_spec)
  end

  test "update the image tag", %{api_spec: api_spec} do
    dockerfile = """
    FROM FreeBSD:testing
    CMD /bin/sleep 10
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "tagging:test"
    }

    {%Schemas.Image{id: image_id}, _build_log} = TestHelper.image_valid_build(config)

    assert %{message: "image not found"} ==
             TestHelper.image_tag(api_spec, "notexist", "newtag:latest")

    assert %{id: image_id} == TestHelper.image_tag(api_spec, image_id, "newtag:latest")

    [%{id: ^image_id, name: "newtag", tag: "latest"}, %{id: "base"}] =
      TestHelper.image_list(api_spec)
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
    FROM FreeBSD:testing
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

  test "build and inspect an image", %{api_spec: api_spec} do
    dockerfile = """
    FROM FreeBSD:testing
    CMD /etc/rc
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {%Schemas.Image{}, _build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:inspect"
      })

    response = TestHelper.image_inspect_raw("testlol:inspect")
    assert response.status == 404
    response = TestHelper.image_inspect_raw("test:inspect")
    assert response.status == 200
    result = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(result, "Image", api_spec)
  end

  test "pruning of images with all=true", %{api_spec: api_spec} do
    base_image = MetaData.get_image("base")
    # Image with no children and a tag
    build_dummy_image("FreeBSD:testing", "test:no-children")

    # Image with no children and no tag
    build_dummy_image("FreeBSD:testing", "")

    # Image with children and a tag
    image = build_dummy_image("FreeBSD:testing", "test:with-children")
    build_dummy_image(image.id, "test:child1")
    build_dummy_image(image.id, "")

    # Image with children and no tag
    image = build_dummy_image("FreeBSD:testing", "")
    build_dummy_image(image.id, "test:child2")
    build_dummy_image(image.id, "")

    TestHelper.image_prune(api_spec, true)
    assert [base_image] == MetaData.list_images()

    # Image with no children and a tag
    image1 = build_dummy_image("FreeBSD:testing", "test:no-children")

    # Image with no children and no tag
    _deleted = build_dummy_image("FreeBSD:testing", "")

    # Image with children and a tag
    image2 = build_dummy_image("FreeBSD:testing", "test:with-children")
    image3 = build_dummy_image(image2.id, "test:child1")
    _deleted = build_dummy_image(image2.id, "")

    # Image with children and no tag
    image4 = build_dummy_image("FreeBSD:testing", "")
    image5 = build_dummy_image(image4.id, "test:child2")
    _deleted = build_dummy_image(image4.id, "")

    TestHelper.image_prune(api_spec, false)

    assert [image5, image4, image3, image2, image1, base_image] ==
             MetaData.list_images()
  end

  test "pruning with all=false", %{api_spec: api_spec} do
    base_image = MetaData.get_image("base")

    # Image with no children and a tag + Image with no children and no tag
    image1 = build_dummy_image("FreeBSD:testing", "test:no-children")
    _deleted = build_dummy_image("FreeBSD:testing", "")

    Kleened.Core.Image.prune(false)
    assert [image1, base_image] == MetaData.list_images()
    Kleened.Core.Image.destroy(image1.id)

    # Image with children and a tag
    image1 = build_dummy_image("FreeBSD:testing", "test:with-children")
    image2 = build_dummy_image(image1.id, "test:child1")
    _deleted = build_dummy_image(image1.id, "")

    TestHelper.image_prune(api_spec, false)
    assert [image2, image1, base_image] == MetaData.list_images()
    Kleened.Core.Image.destroy(image2.id)
    Kleened.Core.Image.destroy(image1.id)

    # Image with children and no tag
    image1 = build_dummy_image("FreeBSD:testing", "")
    image2 = build_dummy_image(image1.id, "test:child2")
    _deleted = build_dummy_image(image1.id, "")
    TestHelper.image_prune(api_spec, false)
    assert [image2, image1, base_image] == MetaData.list_images()
  end

  test "pruning images with containers and all=false", %{api_spec: api_spec} do
    base_image = MetaData.get_image("base")
    # Image with no children and a tag
    image1 = build_dummy_image("FreeBSD:testing", "test:no-children")
    TestHelper.container_create(api_spec, %{name: "prune1", image: image1.id})

    # Image with no children and no tag
    image2 = build_dummy_image("FreeBSD:testing", "")
    TestHelper.container_create(api_spec, %{name: "prune2", image: image2.id})
    TestHelper.image_prune(api_spec, false)
    assert [image2, image1, base_image] == MetaData.list_images()
  end

  test "pruning images with containers and all=true", %{api_spec: api_spec} do
    base_image = MetaData.get_image("base")

    # Image with children and a tag
    image1 = build_dummy_image("FreeBSD:testing", "test:with-children")
    image2 = build_dummy_image(image1.id, "test:child1")
    build_dummy_image(image1.id, "")
    TestHelper.container_create(api_spec, %{name: "prune3", image: image2.id})

    # Image with children and no tag
    image3 = build_dummy_image("FreeBSD:testing", "")
    build_dummy_image(image3.id, "test:child2")
    image4 = build_dummy_image(image3.id, "")
    TestHelper.container_create(api_spec, %{name: "prune4", image: image4.id})

    TestHelper.image_prune(api_spec, true)

    assert [image4, image3, image2, image1, base_image] == MetaData.list_images()
  end

  test "verify 'WORKDIR' behaviour: Absolute path and auto-creation" do
    dockerfile = """
    FROM FreeBSD:testing
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

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_output = [
      "/testdir\n",
      "/home\n"
    ]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)
    {%Schemas.Image{layer_id: layer_id}, build_log} = TestHelper.image_valid_build(config)
    assert expected_output == build_log
    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "/testdir/testfile")) == {:ok, "lol\n"}
    assert File.read(Path.join(mountpoint, "/home/test.txt")) == {:ok, "lol\n"}
  end

  test "verify 'WORKDIR' behaviour: Relative path" do
    dockerfile = """
    FROM FreeBSD:testing
    WORKDIR /a
    WORKDIR b
    WORKDIR c
    RUN pwd
    WORKDIR /home
    RUN pwd
    """

    context = create_test_context("test_copy_instruction")

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_log = [
      "/a/b/c\n",
      "/home\n"
    ]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)
    {_image, build_log} = TestHelper.image_valid_build(config)
    assert expected_log == build_log
  end

  test "create an image with a 'COPY' instruction" do
    dockerfile = """
    FROM FreeBSD:testing
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

  test "create an image with a 'COPY' instruction where <dest> does exist yet" do
    dockerfile = """
    FROM FreeBSD:testing
    COPY test.txt /root/lol/
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
    assert File.read(Path.join(mountpoint, "root/lol/test.txt")) == {:ok, "lol\n"}
    assert MetaData.list_containers() == []
  end

  test "create an image with a wildcard-expandable 'COPY' instruction" do
    dockerfile = """
    FROM FreeBSD:testing
    COPY *.txt /root/
    """

    context = create_test_context("test_expanded_copy_instruction")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    {%Schemas.Image{layer_id: layer_id}, _build_log} = TestHelper.image_valid_build(config)

    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
    assert File.read(Path.join(mountpoint, "root/test2.txt")) == {:ok, "lel\n"}
    assert MetaData.list_containers() == []
  end

  test "create an image with a 'COPY' instruction using symlinks" do
    dockerfile = """
    FROM FreeBSD:testing
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
    FROM FreeBSD:testing
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

    config = %{name: "test-cmd-instruc", image: image_id}

    {container, exec_id} = TestHelper.container_start_attached(api_spec, config)

    assert TestHelper.collect_container_output(exec_id) == "lol"
    Kleened.Core.Container.remove(container.id)
  end

  test "create an image with 'ENV' instructions using basic notations" do
    dockerfile = """
    FROM FreeBSD:testing
    ENV TEST1=lol
    ENV TEST2="testing test"
    ENV TEST3=test\ test
    RUN  printenv
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {image, build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    assert build_log == ["PWD=/\nTEST1=lol\nTEST2=testing test\nTEST3=test test\n"]
    assert Enum.sort(image.env) == ["TEST1=lol", "TEST2=testing test", "TEST3=test test"]
  end

  test "create an image with a quoted and escaped ENV-instruction" do
    dockerfile = """
    FROM FreeBSD:testing
    ENV TEST="\\$5\\$2Fun7BK4thgtd4ao\\$j1kidg9P"
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

  test "verify that RUN instructions uses the ENV variables set earlier in the Dockerfile" do
    dockerfile = """
    FROM FreeBSD:testing
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
      "PWD=/\nTEST=testvalue\n",
      "PWD=/\nTEST=a new test value for TEST\nTEST2=test2value\n"
    ]

    assert expected_build_log == build_log
    assert Enum.sort(image.env) == ["TEST2=test2value", "TEST=a new test value for TEST"]
  end

  test "create image with a FROM instruction that uses a predefined ARG-value" do
    dockerfile = """
    ARG testvar
    FROM ${testvar:-doesnotexist}
    RUN echo "succesfully used parent image"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    build_log_passed = [
      "succesfully used parent image\n"
    ]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {:failed_build, _image_id, build_log} = TestHelper.image_invalid_build(config)
    assert last_log_entry(build_log) == "parent image not found"

    config = Map.put(config, :buildargs, %{"testvar" => "FreeBSD:testing"})
    {_image, build_log} = TestHelper.image_valid_build(config)

    assert build_log_passed == build_log
  end

  test "fail to create image with a non-ARG instruction before the FROM instruction" do
    dockerfile = """
    ENV testvar=lol
    FROM FreeBSD:testing
    RUN echo "this never happens"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {:invalid_dockerfile, _build_id, build_log} = TestHelper.image_invalid_build(config)

    assert last_log_entry(build_log) ==
             "error in 'ENV testvar=lol': instruction not permitted before a FROM instruction"
  end

  test "create image with ARG-variable without an explicit default value, thus empty string" do
    dockerfile = """
    FROM FreeBSD:testing
    ARG testvar
    RUN echo "lol:$testvar"
    RUN echo "lol:${testvar:-empty}"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, build_log} = TestHelper.image_valid_build(config)
    assert ["lol:\n", "lol:empty\n"] == build_log

    config = Map.put(config, :buildargs, %{"testvar" => "testval"})
    {_image, build_log} = TestHelper.image_valid_build(config)

    assert ["lol:testval\n", "lol:testval\n"] == build_log
  end

  test "create image with ARG-variable with default value" do
    dockerfile = """
    FROM FreeBSD:testing
    ARG testvar1=testval1
    ARG testvar2="test val2"
    RUN echo "$testvar1:$testvar2"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, build_log} = TestHelper.image_valid_build(config)
    assert ["testval1:test val2\n"] == build_log

    config = Map.put(config, :buildargs, %{"testvar1" => "newval1", "testvar2" => "newval2"})
    {_image, build_log} = TestHelper.image_valid_build(config)
    assert ["newval1:newval2\n"] == build_log
  end

  test "test precedenice ARG-variable definition: Client vs. Dockerfile" do
    dockerfile = """
    FROM FreeBSD:testing
    USER ${username:-ntpd}
    ARG username
    RUN whoami
    USER $username
    RUN whoami
    """

    expected_build_log = [
      "ntpd\n",
      "games\n"
    ]

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest",
      buildargs: %{"username" => "games"}
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    {_image, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log
  end

  test "test that ENV-instruction always override an ARG-instruction" do
    dockerfile = """
    FROM FreeBSD:testing
    ARG CONT_IMG_VER
    ENV CONT_IMG_VER=v1.0.0
    RUN echo $CONT_IMG_VER
    """

    expected_build_log = ["v1.0.0\n"]

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest",
      buildargs: %{"CONT_IMG_VER" => "v2.0.1"}
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    {_image, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log
  end

  test "Test ARG-variable persistence using ENV-variable and CMD environement substitution", %{
    api_spec: api_spec
  } do
    dockerfile = """
    FROM FreeBSD:testing
    ARG CONT_IMG_VER
    ENV CONT_IMG_VER=${CONT_IMG_VER:-v1.0.0}
    CMD echo $CONT_IMG_VER
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    # Build and run _without_ supplied buildarg
    {image, build_log} = TestHelper.image_valid_build(config)
    assert [] == build_log

    {container, exec_id} =
      TestHelper.container_start_attached(api_spec, %{name: "test-arg2env", image: image.id})

    assert TestHelper.collect_container_output(exec_id) == "v1.0.0\n"
    Kleened.Core.Container.remove(container.id)

    # Build and run _with_ supplied buildarg
    config = Map.put(config, :buildargs, %{"CONT_IMG_VER" => "v.2.0.1"})
    {image, build_log} = TestHelper.image_valid_build(config)
    assert [] == build_log

    {container, exec_id} =
      TestHelper.container_start_attached(api_spec, %{name: "test-arg2env", image: image.id})

    assert TestHelper.collect_container_output(exec_id) == "v.2.0.1\n"
    Kleened.Core.Container.remove(container.id)
  end

  test "invalid ENV and ARG variable names" do
    dockerfile = """
    FROM FreeBSD:testing
    ARG TEST-VAR="this should fail"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    {:invalid_dockerfile, _build_id, build_log} = TestHelper.image_invalid_build(config)

    assert build_log == [
             "ENV/ARG variable name is invalid on line: ARG TEST-VAR=\"this should fail\""
           ]

    dockerfile = """
    FROM FreeBSD:testing
    ENV TEST-VAR="this should fail"
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)
    {:invalid_dockerfile, _build_id, build_log} = TestHelper.image_invalid_build(config)

    assert build_log == [
             "ENV/ARG variable name is invalid on line: ENV TEST-VAR=\"this should fail\""
           ]
  end

  test "create arg-variable and use with USER-instruction" do
    dockerfile = """
    FROM FreeBSD:testing
    ARG TESTVAR=ntpd
    USER $TESTVAR
    RUN echo "$(/usr/bin/id)"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, build_log} = TestHelper.image_valid_build(config)
    assert ["uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"] == build_log
  end

  test "create ARG-variable and use with COPY instruction" do
    dockerfile = """
    FROM FreeBSD:testing
    ARG TESTVAR="test.txt"
    COPY $TESTVAR /root/
    """

    context = create_test_context("test_arg_with_copy_instruction")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    config = %{
      context: context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    {%Schemas.Image{layer_id: layer_id}, build_log} = TestHelper.image_valid_build(config)

    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)

    assert [] == build_log
    assert File.read(Path.join(mountpoint, "root/test.txt")) == {:ok, "lol\n"}
  end

  test "declaring a ARG-variable a second time overrides the first value" do
    dockerfile = """
    FROM FreeBSD:testing
    ARG testvar=should_be_overwritten
    ARG testvar
    RUN echo -n "empty:$testvar"
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_build_log = ["empty:"]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log
  end

  test "ENV instructions takes precedence over ARG-instructions" do
    dockerfile = """
    FROM FreeBSD:testing
    ARG CONT_IMG_VER
    ENV CONT_IMG_VER=v1.0.0
    RUN echo $CONT_IMG_VER
    """

    config = %{
      context: @tmp_context,
      dockerfile: @tmp_dockerfile,
      tag: "test:latest"
    }

    expected_build_log = ["v1.0.0\n"]

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {_image, build_log} = TestHelper.image_valid_build(config)
    assert expected_build_log == build_log
  end

  test "create an image using three RUN/COPY instructions" do
    dockerfile = """
    FROM FreeBSD:testing
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
    FROM FreeBSD:testing
    COPY test.txt /root/
    RUN echo \
      "this should not be relayed back to the parent process"
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

    assert build_log == []
  end

  test "creating a container using a snapshot from an image-build", %{api_spec: api_spec} do
    dockerfile = """
    FROM FreeBSD:testing
    COPY test.txt /etc/
    RUN echo -n "some text" > /etc/test2.txt
    CMD /etc/rc
    """

    context = create_test_context("test_image_snapshots")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    {image, _build_log} =
      TestHelper.image_valid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    snapshot = fetch_snapshot(image, "COPY test.txt /etc/")

    {_closing_msg, process_output} =
      TestHelper.container_run(api_spec, %{
        image: "#{image.id}:#{snapshot}",
        attach: true,
        cmd: ["/bin/cat", "/etc/test.txt"]
      })

    assert process_output == ["lol\n"]

    {_closing_msg, process_output} =
      TestHelper.container_run(api_spec, %{
        image: "#{image.id}:#{snapshot}",
        attach: true,
        cmd: ["/bin/cat", "/etc/test2.txt"]
      })

    assert process_output == [
             "cat: /etc/test2.txt: No such file or directory\n",
             "jail: /usr/bin/env -i /bin/cat /etc/test2.txt: failed\n"
           ]

    snapshot = fetch_snapshot(image, "RUN echo -n \"some text\" > /etc/test2.txt")

    {_closing_msg, process_output} =
      TestHelper.container_run(api_spec, %{
        image: "test:latest:#{snapshot}",
        attach: true,
        cmd: ["/bin/cat", "/etc/test2.txt"]
      })

    assert process_output == ["some text"]
  end

  test "creating a container using a snapshot from a failed image-build", %{api_spec: api_spec} do
    dockerfile = """
    FROM FreeBSD:testing
    COPY test.txt /etc/
    RUN ls notexist
    RUN echo -n "some text" > /etc/test2.txt
    CMD /etc/rc
    """

    context = create_test_context("test_image_snapshots2")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    {_error_type, image_id, _build_log} =
      TestHelper.image_invalid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest",
        cleanup: false
      })

    image = MetaData.get_image(image_id)
    snapshot = fetch_snapshot(image, "COPY test.txt /etc/")

    {_closing_msg, process_output} =
      TestHelper.container_run(api_spec, %{
        image: "#{image.id}:#{snapshot}",
        attach: true,
        cmd: ["/bin/cat", "/etc/test.txt"]
      })

    assert process_output == ["lol\n"]

    {_closing_msg, process_output} =
      TestHelper.container_run(api_spec, %{
        image: "#{image.id}:#{snapshot}",
        attach: true,
        cmd: ["/bin/cat", "/etc/test2.txt"]
      })

    assert process_output == [
             "cat: /etc/test2.txt: No such file or directory\n",
             "jail: /usr/bin/env -i /bin/cat /etc/test2.txt: failed\n"
           ]
  end

  # The mini-jail userland used for the 'fetch' and 'zfs' image creation tests
  # have been created with https://github.com/Freaky/mkjail using the command
  # mkjail -a minimal_testjail.txz /usr/bin/env -i /usr/local/bin/python3.9 -c "print('lol')"
  test "create base image using a method 'zfs'", %{api_spec: api_spec} do
    dataset = "zroot/image_create_zfs_test"
    ZFS.create(dataset)

    {_, 0} =
      OS.cmd(["/usr/bin/tar", "-xf", "./test/data/minimal_testjail.txz", "-C", "/#{dataset}"])

    config = %{
      method: "zfs",
      zfs_dataset: dataset,
      tag: "zfscreate:testing"
    }

    frames = TestHelper.image_create(config)
    {{1000, closing_msg}, _rest} = List.pop_at(frames, -1)
    assert %Message{data: _, message: "image created", msg_type: "closing"} = closing_msg

    {_cont, exec_id} =
      TestHelper.container_start_attached(api_spec, %{
        name: "testcont",
        image: closing_msg.data,
        cmd: ["/usr/local/bin/python3.9", "-c", "print('testing minimaljail')"],
        jail_param: ["exec.system_jail_user"],
        user: "root"
      })

    assert_receive {:container, ^exec_id, {:jail_output, jail_output}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}
    assert jail_output == "testing minimaljail\n"
    ZFS.destroy_force(dataset)
  end

  test "create base image using a method 'fetch'", %{api_spec: api_spec} do
    config = %{
      method: "fetch",
      url: "file://./test/data/minimal_testjail.txz",
      tag: "fetchcreate:testing"
    }

    frames = TestHelper.image_create(config)
    {{1000, closing_msg}, _rest} = List.pop_at(frames, -1)

    assert %Message{data: _, message: "image created", msg_type: "closing"} = closing_msg

    {_cont, exec_id} =
      TestHelper.container_start_attached(api_spec, %{
        name: "testcont",
        image: closing_msg.data,
        cmd: ["/usr/local/bin/python3.9", "-c", "print('testing minimaljail')"],
        jail_param: ["exec.system_jail_user"],
        user: "root"
      })

    assert_receive {:container, ^exec_id, {:jail_output, jail_output}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}
    assert jail_output == "testing minimaljail\n"
  end

  test "image-build stops prematurely from non-zero exitcode from RUN-instruction" do
    dockerfile = """
    FROM FreeBSD:testing
    RUN ls notexist
    RUN echo "this should not be executed"
    """

    context = create_test_context("test_image_run_nonzero_exitcode")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    {:failed_build, _image_id, build_log} =
      TestHelper.image_invalid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile
      })

    assert last_log_entry(build_log) ==
             "The command '/bin/sh -c ls notexist' returned a non-zero code: 1"
  end

  test "image-build stops prematurely from non-zero exitcode but creates the image anyway", %{
    api_spec: api_spec
  } do
    dockerfile = """
    FROM FreeBSD:testing
    RUN echo "test" > /etc/testing
    RUN ls notexist
    """

    context = create_test_context("test_image_run_nonzero_exitcode")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    {:failed_build, image_id, {build_log, _snapshot}} =
      TestHelper.image_invalid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile,
        quiet: false,
        cleanup: false,
        tag: "test-nocleanup:latest"
      })

    assert last_log_entry(build_log) ==
             "The command '/bin/sh -c ls notexist' returned a non-zero code: 1"

    config = %{
      name: "testcont",
      image: image_id,
      cmd: ["/bin/cat", "/etc/testing"]
    }

    {_cont, exec_id} = TestHelper.container_start_attached(api_spec, config)
    assert_receive {:container, ^exec_id, {:jail_output, "test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}
  end

  test "try building an image from a invalid Dockerfile (no linebreak)" do
    dockerfile = """
    FROM FreeBSD:testing
    RUN echo
      "this should faile because we omitted the '\\' above"
    CMD /usr/bin/uname
    """

    context = create_test_context("test_image_builder_three_layers")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    {:invalid_dockerfile, _build_id, build_log} =
      TestHelper.image_invalid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile
      })

    assert last_log_entry(build_log) ==
             "invalid instruction:   \"this should faile because we omitted the '\\' above\""
  end

  test "try building an image with an invalid image name in the FROM-instruction" do
    dockerfile = """
    FROM nonexisting
    CMD /bin/ls
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, @tmp_context)

    {:failed_build, _image_id, build_log} =
      TestHelper.image_invalid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile
      })

    assert build_log == ["Step 1/2 : FROM nonexisting\n", "parent image not found"]
  end

  test "try building an image from a invalid Dockerfile (illegal comment)" do
    dockerfile = """
    FROM FreeBSD:testing
    ENV TEST="something" # You cannot make comments like this.
    """

    context = create_test_context("test_image_builder_three_layers")
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile, context)

    {:failed_build, _image_id, build_log} =
      TestHelper.image_invalid_build(%{
        context: context,
        dockerfile: @tmp_dockerfile,
        tag: "test:latest"
      })

    assert build_log == [
             "Step 1/2 : FROM FreeBSD:testing\n",
             "Step 2/2 : ENV TEST=\"something\" # You cannot make comments like this.\n",
             "failed environment substition of: ENV TEST=\"something\" # You cannot make comments like this."
           ]
  end

  defp build_dummy_image(parent_image, image_tag) do
    create_dockerfile = fn parent ->
      """
      FROM #{parent}
      CMD /etc/rc
      """
    end

    dockerfile = create_dockerfile.(parent_image)
    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    {%Schemas.Image{} = image, _build_log} =
      TestHelper.image_valid_build(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        tag: image_tag
      })

    image
  end

  defp fetch_snapshot(%Schemas.Image{instructions: instructions}, instruction) do
    [^instruction, snapshot] =
      Enum.find(instructions, nil, fn [instruct, _] ->
        instruct == instruction
      end)

    snapshot
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
