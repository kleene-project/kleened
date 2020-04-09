defmodule ContainerTest do
  use ExUnit.Case
  import Jocker.Records

  setup_all do
    Jocker.ZFS.clear_zroot()
  end

  setup do
    start_supervised(%{
      :id => Jocker.MetaData,
      :start => {Jocker.MetaData, :start_link, []}
    })

    start_supervised(%{
      :id => Jocker.Layer,
      :start => {Jocker.Layer, :start_link, []}
    })

    start_supervised(%{
      :id => Jocker.Network,
      :start => {Jocker.Network, :start_link, [{"10.13.37.1", "10.13.37.255"}, "jocker0"]}
    })

    :ok
  end

  test "create a container and fetch metadata" do
    image(id: id) = Jocker.MetaData.get_image("base")
    {:ok, pid} = Jocker.Container.create([])
    container(image_id: img_id) = Jocker.Container.metadata(pid)
    assert id == img_id
  end

  test "start a container (using devfs), attach to it and receive output" do
    opts = [
      cmd: ["/bin/echo", "test test"],
      jail_param: ["mount.devfs"]
    ]

    {:ok, pid} = Jocker.Container.create(opts)
    :ok = Jocker.Container.attach(pid)

    container(command: cmd_out) = container = Jocker.Container.metadata(pid)

    Jocker.Container.start(pid)

    assert opts[:cmd] == cmd_out
    assert_receive {:container, ^pid, "test test\n"}
    assert_receive {:container, ^pid, "jail stopped"}
    assert not devfs_mounted(container)
  end

  test "start and stop a container (using devfs)" do
    opts = [
      cmd: ["/bin/sleep", "1000"],
      jail_param: ["mount.devfs"]
    ]

    {pid, container} = start_attached_container(opts)
    Process.flag(:trap_exit, true)

    assert devfs_mounted(container)
    :ok = Jocker.Container.stop(pid)
    assert_receive {:container, ^pid, "jail stopped"}
    assert_receive {:EXIT, ^pid, :normal}
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
    :ok = Jocker.Container.stop(pid)
    assert not devfs_mounted(container)
  end

  test "start a container as non-root" do
    opts = [
      cmd: ["/usr/bin/id"],
      jail_param: [],
      user: "ntpd"
    ]

    {pid, _container} = start_attached_container(opts)

    assert_receive {:container, ^pid, "jail stopped"}
    assert_receive {:container, ^pid, "uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"}
  end

  defp start_attached_container(opts) do
    {:ok, pid} = Jocker.Container.create(opts)
    :ok = Jocker.Container.attach(pid)
    container = Jocker.Container.metadata(pid)
    Jocker.Container.start(pid)
    {pid, container}
  end

  defp devfs_mounted(container(layer: layer(mountpoint: mountpoint))) do
    devfs_path = Path.join(mountpoint, "dev")

    case System.cmd("sh", ["-c", "mount | grep \"devfs on #{devfs_path}\""]) do
      {"", 1} -> false
      {_output, 0} -> true
    end
  end
end
