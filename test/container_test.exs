defmodule ContainerTest do
  use ExUnit.Case
  alias Jocker.Engine.{Container, Image, Exec}

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

    {:ok, %Container{id: container_id, command: command} = container} =
      TestHelper.create_container("testcont", %{cmd: cmd_expected})

    assert cmd_expected == command

    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: true, start_container: true})

    assert_receive {:container, ^exec_id, {:jail_output, "test test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}
    assert not TestHelper.devfs_mounted(container)
  end

  test "start and stop a container (using devfs)" do
    config = %{cmd: ["/bin/sleep", "10"]}
    {cont, exec_id} = TestHelper.start_attached_container("testcont", config)

    assert TestHelper.devfs_mounted(cont)

    assert {:ok, "succesfully closed container"} = Exec.stop(exec_id, %{stop_container: true})

    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}
    assert not TestHelper.devfs_mounted(cont)
  end

  test "try to start a running executable" do
    start_opts = %{start_container: true, attach: false}
    stop_opts = %{stop_container: true, force_stop: false}

    {_container, exec_id} =
      TestHelper.start_attached_container("testcont", %{cmd: ["/bin/sleep", "10"]})

    assert {:error, "executable already started"} == Exec.start(exec_id, start_opts)
    assert {:ok, "succesfully closed container"} = Exec.stop(exec_id, stop_opts)
  end

  test "start and stop a container with '/etc/rc' (using devfs)" do
    stop_opts = %{stop_container: true, force_stop: false}

    config = %{
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs", "exec.stop=\"/bin/sh /etc/rc.shutdown\""],
      user: "root"
    }

    {cont, exec_id} = TestHelper.start_attached_container("testcont", config)

    assert TestHelper.devfs_mounted(cont)
    assert {:ok, "succesfully closed container"} = Exec.stop(exec_id, stop_opts)
    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}
    assert not TestHelper.devfs_mounted(cont)
  end

  test "create container from non-existing image" do
    assert {:error, :image_not_found} ==
             TestHelper.create_container("testcont", %{image: "nonexisting"})
  end

  test "start a container as non-root" do
    {_cont, exec_id} =
      TestHelper.start_attached_container("testcont", %{cmd: ["/usr/bin/id"], user: "ntpd"})

    assert_receive {:container, ^exec_id,
                    {:jail_output, "uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"}}

    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}
  end

  test "start a container with environment variables set" do
    config = %{
      cmd: ["/bin/sh", "-c", "printenv"],
      env: ["LOL=test", "LOOL=test2"],
      user: "root"
    }

    {_cont, exec_id} = TestHelper.start_attached_container("testcont", config)

    assert_receive {:container, ^exec_id, {:jail_output, "PWD=/\nLOOL=test2\nLOL=test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}
  end

  test "start a container with environment variables" do
    dockerfile = """
    FROM scratch
    ENV TEST=lol
    ENV TEST2="lool test"
    CMD /bin/sh -c "printenv"
    """

    TestHelper.create_tmp_dockerfile(dockerfile, "tmp_dockerfile")
    {image, _messages} = TestHelper.build_and_return_image("./", "tmp_dockerfile", "test:latest")

    config = %{
      image: image.id,
      env: ["TEST3=loool"],
      cmd: ["/bin/sh", "-c", "printenv"]
    }

    {container, exec_id} = TestHelper.start_attached_container("testcont", config)

    assert_receive {:container, ^exec_id, {:jail_output, env_vars}}
    env_vars_set = String.trim(env_vars, "\n") |> String.split("\n") |> MapSet.new()
    expected_set = MapSet.new(["PWD=/", "TEST=lol", "TEST2=lool test", "TEST3=loool"])
    assert MapSet.equal?(env_vars_set, expected_set)

    Container.destroy(container.id)
    Image.destroy(image.id)
  end

  test "start a container with environment variables and overwrite one of them" do
    dockerfile = """
    FROM scratch
    ENV TEST=lol
    ENV TEST2="lool test"
    CMD /bin/sh -c "printenv"
    """

    TestHelper.create_tmp_dockerfile(dockerfile, "tmp_dockerfile")
    {image, _messages} = TestHelper.build_and_return_image("./", "tmp_dockerfile", "test:latest")

    config = %{
      image: image.id,
      env: ["TEST=new_value"],
      cmd: ["/bin/sh", "-c", "printenv"]
    }

    {container, exec_id} = TestHelper.start_attached_container("testcont", config)

    assert_receive {:container, ^exec_id, {:jail_output, env_vars}}
    env_vars_set = String.trim(env_vars, "\n") |> String.split("\n") |> MapSet.new()
    expected_set = MapSet.new(["PWD=/", "TEST=new_value", "TEST2=lool test"])
    assert MapSet.equal?(env_vars_set, expected_set)

    Container.destroy(container.id)
    Image.destroy(image.id)
  end
end
