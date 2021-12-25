defmodule ContainerTest do
  use ExUnit.Case
  alias Jocker.Engine.{Container, Image}

  @moduletag :capture_log

  setup do
    on_exit(fn ->
      Jocker.Engine.MetaData.list_containers()
      |> Enum.map(fn %{id: id} -> Container.destroy(id) end)
    end)

    :ok
  end

  test "plug testing container and fetch metadata" do
    {:ok, %Container{image_id: img_id}} = TestHelper.create_container("testcont", %{})
    %Image{id: id} = Jocker.Engine.MetaData.get_image("base")
    assert id == img_id
  end

  test "start a container (using devfs), attach to it and receive output" do
    cmd_expected = ["/bin/echo", "test test"]

    {:ok, %Container{id: id} = container} =
      TestHelper.create_container("testcont", %{cmd: cmd_expected})

    :ok = Container.attach(id)
    Container.start(id)

    assert cmd_expected == container.command
    assert_receive {:container, ^id, {:jail_output, "test test\n"}}
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
    assert not TestHelper.devfs_mounted(container)
  end

  test "start and stop a container (using devfs)" do
    config = %{cmd: ["/bin/sleep", "10"]}
    %Container{id: id} = cont = TestHelper.start_attached_container("testcont", config)

    assert TestHelper.devfs_mounted(cont)
    assert {:ok, %Container{id: ^id}} = Container.stop(id)
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
    assert not TestHelper.devfs_mounted(cont)
  end

  test "try to start a running container" do
    %Container{id: id} =
      TestHelper.start_attached_container("testcont", %{cmd: ["/bin/sleep", "10"]})

    assert {:error, :already_started} == Container.start(id)
    assert {:ok, %Container{id: ^id}} = Container.stop(id)
  end

  test "start and stop a container with '/etc/rc' (using devfs)" do
    config = %{
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs", "exec.stop=\"/bin/sh /etc/rc.shutdown\""],
      user: "root"
    }

    %Container{id: id} = cont = TestHelper.start_attached_container("testcont", config)

    assert TestHelper.devfs_mounted(cont)
    assert {:ok, %Container{id: ^id}} = Container.stop(id)
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
    assert not TestHelper.devfs_mounted(cont)
  end

  test "create container from non-existing image" do
    assert {:error, :image_not_found} ==
             TestHelper.create_container("testcont", %{image: "nonexisting"})
  end

  test "create container from non-existing id" do
    assert {:error, :not_found} ==
             Jocker.Engine.Container.start("nonexisting_id")
  end

  test "start a container as non-root" do
    %Container{id: id} =
      TestHelper.start_attached_container("testcont", %{cmd: ["/usr/bin/id"], user: "ntpd"})

    assert_receive {:container, ^id,
                    {:jail_output, "uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"}}

    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
  end

  test "start a container with environment variables set" do
    config = %{
      cmd: ["/bin/sh", "-c", "printenv"],
      env: ["LOL=test", "LOOL=test2"],
      user: "root"
    }

    %Container{id: id} = TestHelper.start_attached_container("testcont", config)

    right_messsage_received =
      receive do
        {:container, ^id, {:jail_output, "PWD=/\nLOOL=test2\nLOL=test\n"}} ->
          true

        msg ->
          IO.puts("\nUnknown message received: #{inspect(msg)}")
          false
      end

    assert right_messsage_received
  end

  test "start a container with environment variables" do
    dockerfile = """
    FROM scratch
    ENV TEST=lol
    ENV TEST2="lool test"
    CMD /bin/sh -c "printenv"
    """

    TestHelper.create_tmp_dockerfile(dockerfile, "tmp_dockerfile")
    image = TestHelper.build_and_return_image("./", "tmp_dockerfile", "test:latest")

    config = %{
      image: image.id,
      env: ["TEST3=loool"],
      cmd: ["/bin/sh", "-c", "printenv"]
    }

    %Container{id: id} = TestHelper.start_attached_container("testcont", config)

    assert_receive {:container, ^id,
                    {:jail_output, "PWD=/\nTEST2=lool test\nTEST=lol\nTEST3=loool\n"}}

    Container.destroy(id)
    Image.destroy(image.id)
  end
end
