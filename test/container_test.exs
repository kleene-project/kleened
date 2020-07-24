defmodule ContainerTest do
  use ExUnit.Case
  alias Jocker.Engine.Config
  alias Jocker.Engine.Container
  import Jocker.Engine.Records

  @moduletag :capture_log

  setup_all do
    Application.stop(:jocker)
    start_supervised(Config)
    TestUtils.clear_zroot()

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
    container(pid: pid, command: cmd_out) = cont
    :ok = Container.attach(pid)

    Container.start(pid)

    assert opts[:cmd] == cmd_out
    assert_receive {:container, ^pid, "test test\n"}
    assert_receive {:container, ^pid, {:shutdown, :jail_stopped}}
    assert not TestUtils.devfs_mounted(cont)
  end

  test "start and stop a container (using devfs)" do
    opts = [
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs"]
    ]

    {pid, container} = start_attached_container(opts)

    assert TestUtils.devfs_mounted(container)
    :ok = Container.stop(pid)
    assert_receive {:container, ^pid, {:shutdown, :jail_stopped}}
    assert not TestUtils.devfs_mounted(container)
  end

  test "try to re-create a running container" do
    opts = [
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs"]
    ]

    {pid, container(id: id)} = start_attached_container(opts)

    {:already_running, container(id: ^id, pid: ^pid) = cont} =
      Container.create(existing_container: id)
  end

  test "start and stop a container with '/etc/rc' (using devfs)" do
    opts = [
      cmd: ["/bin/sh", "/etc/rc"],
      jail_param: ["mount.devfs", "exec.stop=\"/bin/sh /etc/rc.shutdown\""],
      user: "root"
    ]

    {pid, container} = start_attached_container(opts)

    assert TestUtils.devfs_mounted(container)
    :ok = Container.stop(pid)
    assert_receive {:container, ^pid, {:shutdown, :jail_stopped}}
    assert not TestUtils.devfs_mounted(container)
  end

  test "create container from non-existing image" do
    assert :image_not_found == Jocker.Engine.Container.create(image: "nonexisting")
  end

  test "create container from non-existing id" do
    assert :container_not_found ==
             Jocker.Engine.Container.create(existing_container: "nonexisting")
  end

  test "start a container as non-root" do
    opts = [
      cmd: ["/usr/bin/id"],
      user: "ntpd"
    ]

    {pid, _container} = start_attached_container(opts)

    assert_receive {:container, ^pid, "uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"}
    assert_receive {:container, ^pid, {:shutdown, :jail_stopped}}
  end

  defp start_attached_container(opts) do
    {:ok, container(pid: pid) = cont} = Container.create(opts)
    :ok = Container.attach(pid)
    Container.start(pid)
    {pid, cont}
  end
end
