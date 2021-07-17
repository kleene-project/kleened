defmodule ContainerTest do
  use ExUnit.Case
  alias Jocker.Engine.{Container, Image}

  @moduletag :capture_log

  test "create container and fetch metadata" do
    %Image{id: id} = Jocker.Engine.MetaData.get_image("base")
    {:ok, %Container{image_id: img_id}} = Container.create([])
    assert id == img_id
  end

  test "start a container (using devfs), attach to it and receive output" do
    opts = [
      cmd: ["/bin/echo", "test test"],
      jail_param: ["mount.devfs"]
    ]

    {:ok, cont} = Container.create(opts)
    %Container{id: id, pid: _pid, command: cmd_out} = cont
    :ok = Container.attach(id)

    Container.start(id)

    assert opts[:cmd] == cmd_out
    assert_receive {:container, ^id, "test test\n"}
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
    assert not TestHelper.devfs_mounted(cont)
  end

  test "start and stop a container (using devfs)" do
    opts = [
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs"]
    ]

    %Container{id: id} = cont = start_attached_container(opts)

    assert TestHelper.devfs_mounted(cont)
    assert {:ok, %Container{id: ^id}} = Container.stop(id)
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
    assert not TestHelper.devfs_mounted(cont)
  end

  test "try to start a running container" do
    opts = [
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs"]
    ]

    %Container{id: id} = start_attached_container(opts)

    assert :already_started == Container.start(id)
    assert {:ok, %Container{id: ^id}} = Container.stop(id)
  end

  test "start and stop a container with '/etc/rc' (using devfs)" do
    opts = [
      cmd: ["/bin/sh", "/etc/rc"],
      jail_param: ["mount.devfs", "exec.stop=\"/bin/sh /etc/rc.shutdown\""],
      user: "root"
    ]

    %Container{id: id} = cont = start_attached_container(opts)

    assert TestHelper.devfs_mounted(cont)
    assert {:ok, %Container{id: ^id}} = Container.stop(id)
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
    assert not TestHelper.devfs_mounted(cont)
  end

  test "create container from non-existing image" do
    assert :image_not_found == Jocker.Engine.Container.create(image: "nonexisting")
  end

  test "create container from non-existing id" do
    assert {:error, :not_found} ==
             Jocker.Engine.Container.start("nonexisting_id")
  end

  test "start a container as non-root" do
    opts = [
      cmd: ["/usr/bin/id"],
      user: "ntpd"
    ]

    %Container{id: id} = start_attached_container(opts)

    assert_receive {:container, ^id, "uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"}
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
  end

  test "start a container with environment variables set" do
    opts = [
      cmd: ["/bin/sh", "-c", "printenv"],
      env: ["LOL=test", "LOOL=test2"],
      user: "root"
    ]

    %Container{id: id} = start_attached_container(opts)

    right_messsage_received =
      receive do
        {:container, ^id, "PWD=/\nLOOL=test2\nLOL=test\n"} ->
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

    opts = [
      image: image.id,
      env: ["TEST3=loool"],
      cmd: ["/bin/sh", "-c", "printenv"]
    ]

    %Container{id: id} = start_attached_container(opts)

    right_messsage_received =
      receive do
        {:container, ^id, "PWD=/\nTEST2=lool test\nTEST=lol\nTEST3=loool\n"} ->
          true

        msg ->
          IO.puts("\nUnknown message received: #{inspect(msg)}")
          false
      end

    assert right_messsage_received
  end

  defp start_attached_container(opts) do
    {:ok, %Container{id: id} = cont} = Container.create(opts)
    :ok = Container.attach(id)
    Container.start(id)
    cont
  end
end
