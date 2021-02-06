defmodule ImageTest do
  use ExUnit.Case
  alias Jocker.Engine.Config
  alias Jocker.Engine.Image
  alias Jocker.Engine.MetaData
  import Jocker.Engine.Records

  @moduletag :capture_log

  @tmp_dockerfile "tmp_dockerfile"
  @tmp_context "./"

  setup_all do
    Application.stop(:jocker)
    TestHelper.clear_zroot()
    start_supervised(Config)
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
    dockerfile = """
    FROM scratch
    RUN echo "lol1" > /root/test_1.txt
    """

    create_tmp_dockerfile(dockerfile)

    image(layer_id: layer_id) =
      build_and_return_image(@tmp_context, @tmp_dockerfile, "test:latest")

    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    assert File.read(Path.join(mountpoint, "/root/test_1.txt")) == {:ok, "lol1\n"}
    assert MetaData.list_containers() == []
  end

  test "create an image with a 'COPY' instruction" do
    dockerfile = """
    FROM scratch
    COPY test.txt /root/
    """

    context = create_test_context("test_copy_instruction")
    create_tmp_dockerfile(dockerfile, context)
    image(layer_id: layer_id) = build_and_return_image(context, @tmp_dockerfile, "test:latest")
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
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
    create_tmp_dockerfile(dockerfile, context)
    image(layer_id: layer_id) = build_and_return_image(context, @tmp_dockerfile, "test:latest")
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    # we cannot check the symbolic link from the host:
    assert File.read(Path.join(mountpoint, "etc/testdir/test.txt")) == {:ok, "lol\n"}
  end

  test "create an image with a 'CMD' instruction" do
    dockerfile = """
    FROM scratch
    CMD  /bin/sleep 10
    """

    create_tmp_dockerfile(dockerfile)
    _image = build_and_return_image(@tmp_context, @tmp_dockerfile, "test:latest")
    assert MetaData.list_containers() == []
  end

  test "create an image using three RUN/COPY instructions" do
    dockerfile = """
    FROM scratch
    COPY test.txt /root/
    RUN echo 'lol1' > /root/test_1.txt
    RUN echo 'lol2' > /root/test_2.txt
    """

    context = create_test_context("test_image_builder_three_layers")
    create_tmp_dockerfile(dockerfile, context)
    image(layer_id: layer_id) = build_and_return_image(context, @tmp_dockerfile, "test:latest")
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
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
    create_tmp_dockerfile(dockerfile, context)
    {:ok, pid} = Image.build(context, @tmp_dockerfile, "test:latest", false)
    {_img, messages} = receive_results(pid, [])

    assert messages == [
             "Step 1/5 : FROM scratch\n",
             "Step 2/5 : COPY test.txt /root/\n",
             "Step 3/5 : RUN echo   \"this should be relayed back to the parent process\"\n",
             "this should be relayed back to the parent process\n",
             "Step 4/5 : USER ntpd\n",
             "Step 5/5 : CMD /etc/rc\n"
           ]
  end

  defp build_and_return_image(context, dockerfile, tag) do
    quiet = true
    {:ok, pid} = Image.build(context, dockerfile, tag, quiet)
    {img, _messages} = receive_results(pid, [])
    img
  end

  defp receive_results(pid, msg_list) do
    receive do
      {:image_builder, ^pid, {:image_finished, img}} ->
        {img, Enum.reverse(msg_list)}

      {:image_builder, ^pid, msg} ->
        receive_results(pid, [msg | msg_list])

      other ->
        IO.puts("\nError! Received unkown message #{inspect(other)}")
    end
  end

  def create_tmp_dockerfile(content, context \\ @tmp_context) do
    :ok = File.write(Path.join(context, @tmp_dockerfile), content, [:write])
  end

  defp create_test_context(name) do
    dataset = Path.join(Config.get("zroot"), name)
    mountpoint = Path.join("/", dataset)
    Jocker.Engine.ZFS.create(dataset)
    {"", 0} = System.cmd("sh", ["-c", "echo 'lol' > #{mountpoint}/test.txt"])
    mountpoint
  end

  defp stop_and_delete_db() do
    # Agent.stop(Jocker.Engine.MetaData)
    File.rm(Config.get("metadata_db"))
  end
end
