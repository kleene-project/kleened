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
      {DynamicSupervisor,
       name: Jocker.Engine.ContainerPool, strategy: :one_for_one, max_restarts: 0}
    )

    :ok
  end

  setup do
    start_supervised(Jocker.Engine.MetaData)
    start_supervised(Jocker.Engine.Layer)
    start_supervised({Jocker.Engine.Network, [{"10.13.37.1", "10.13.37.255"}, "jocker0"]})
    :ok
  end

  test "create container and fetch metadata" do
    image(id: id) = Jocker.Engine.MetaData.get_image("base")
    {:ok, pid} = Container.create([])
    container(image_id: img_id) = Container.metadata(pid)
    assert id == img_id
  end

  test "start a container (using devfs), attach to it and receive output" do
    opts = [
      cmd: ["/bin/echo", "test test"],
      jail_param: ["mount.devfs"]
    ]

    {:ok, pid} = Container.create(opts)
    :ok = Container.attach(pid)

    container(command: cmd_out) = container = Container.metadata(pid)

    Container.start(pid)

    assert opts[:cmd] == cmd_out
    assert_receive {:container, ^pid, "test test\n"}
    assert_receive {:container, ^pid, {:shutdown, :jail_stopped}}
    assert not devfs_mounted(container)
  end

  test "start and stop a container (using devfs)" do
    opts = [
      cmd: ["/bin/sleep", "1000"],
      jail_param: ["mount.devfs"]
    ]

    {pid, container} = start_attached_container(opts)

    assert devfs_mounted(container)
    :ok = Container.stop(pid)
    assert_receive {:container, ^pid, {:shutdown, :jail_stopped}}
    assert not devfs_mounted(container)
  end

  test "start and stop a container with '/etc/rc' (using devfs)" do
    opts = [
      cmd: ["/bin/sh", "/etc/rc"],
      jail_param: ["mount.devfs", "exec.stop=\"/bin/sh /etc/rc.shutdown\""],
      user: "ntpd"
    ]

    {pid, container} = start_attached_container(opts)

    assert devfs_mounted(container)
    :ok = Container.stop(pid)
    assert_receive {:container, ^pid, {:shutdown, :jail_stopped}}
    assert not devfs_mounted(container)
  end

  test "create container from non-existing image" do
    assert :image_not_found == Jocker.Engine.Container.create(image: "nonexisting")
  end

  test "create container from non-existing id" do
    assert :container_not_found == Jocker.Engine.Container.create(id_or_name: "nonexisting")
  end

  test "start a container as non-root" do
    opts = [
      cmd: ["/usr/bin/id"],
      jail_param: [],
      user: "ntpd"
    ]

    {pid, _container} = start_attached_container(opts)

    assert_receive {:container, ^pid, {:shutdown, :jail_stopped}}
    assert_receive {:container, ^pid, "uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"}
  end

  defp start_attached_container(opts) do
    {:ok, pid} = Container.create(opts)
    :ok = Container.attach(pid)
    container = Container.metadata(pid)
    Container.start(pid)
    {pid, container}
  end

  defp devfs_mounted(container(layer_id: layer_id)) do
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    devfs_path = Path.join(mountpoint, "dev")

    case System.cmd("sh", ["-c", "mount | grep \"devfs on #{devfs_path}\""]) do
      {"", 1} -> false
      {_output, 0} -> true
    end
  end
end
