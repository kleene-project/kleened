defmodule ContainerTest do
  use ExUnit.Case
  alias Jocker.Engine.Config
  alias Jocker.Engine.Container
  import Jocker.Engine.Records

  @moduletag :capture_log

  setup_all do
    Application.stop(:jocker)
    TestUtils.clear_zroot()
    start_supervised(Config)

    start_supervised(
      {DynamicSupervisor, name: Jocker.Engine.ContainerPool, strategy: :one_for_one}
    )

    :ok
  end

  setup do
    start_supervised(Jocker.Engine.MetaData)
    start_supervised(Jocker.Engine.Layer)
    start_supervised(Jocker.Engine.Network)
    :ok
  end

  test "create container and fetch metadata" do
    image(id: id) = Jocker.Engine.MetaData.get_image("base")
    {:ok, container(image_id: img_id)} = Container.create([])
    assert id == img_id
  end

  test "start a container (using devfs), attach to it and receive output" do
    opts = [
      cmd: ["/bin/echo", "test test"],
      jail_param: ["mount.devfs"]
    ]

    {:ok, cont} = Container.create(opts)
    container(id: id, pid: _pid, command: cmd_out) = cont
    :ok = Container.attach(id)

    Container.start(id)

    assert opts[:cmd] == cmd_out
    assert_receive {:container, ^id, "test test\n"}
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
    assert not TestUtils.devfs_mounted(cont)
  end

  test "start and stop a container (using devfs)" do
    opts = [
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs"]
    ]

    container(id: id) = cont = start_attached_container(opts)

    assert TestUtils.devfs_mounted(cont)
    assert {:ok, container(id: ^id)} = Container.stop(id)
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
    assert not TestUtils.devfs_mounted(cont)
  end

  test "try to start a running container" do
    opts = [
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs"]
    ]

    container(id: id) = start_attached_container(opts)

    assert :already_started == Container.start(id)
    assert {:ok, container(id: ^id)} = Container.stop(id)
  end

  test "start and stop a container with '/etc/rc' (using devfs)" do
    opts = [
      cmd: ["/bin/sh", "/etc/rc"],
      jail_param: ["mount.devfs", "exec.stop=\"/bin/sh /etc/rc.shutdown\""],
      user: "root"
    ]

    container(id: id) = cont = start_attached_container(opts)

    assert TestUtils.devfs_mounted(cont)
    assert {:ok, container(id: ^id)} = Container.stop(id)
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
    assert not TestUtils.devfs_mounted(cont)
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

    container(id: id) = start_attached_container(opts)

    assert_receive {:container, ^id, "uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"}
    assert_receive {:container, ^id, {:shutdown, :jail_stopped}}
  end

  defp start_attached_container(opts) do
    {:ok, container(id: id) = cont} = Container.create(opts)
    :ok = Container.attach(id)
    Container.start(id)
    cont
  end
end
