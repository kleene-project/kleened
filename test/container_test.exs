defmodule ContainerTest do
  require Logger
  use Kleened.API.ConnCase
  alias Kleened.Core.{Container, Image, Exec, Utils, MetaData}
  alias Kleened.API.Schemas

  @moduletag :capture_log

  setup do
    on_exit(fn ->
      Kleened.Core.MetaData.list_containers()
      |> Enum.map(fn %{id: id} -> Container.remove(id) end)
    end)

    :ok
  end

  test "create, destroy and list containers", %{
    api_spec: api_spec
  } do
    assert [] == TestHelper.container_list(api_spec)

    %Schemas.Container{id: container_id, name: name, image_id: img_id} =
      container_succesfully_create(api_spec, "testcont", %{})

    %Schemas.Image{id: id} = Kleened.Core.MetaData.get_image("base")
    assert id == img_id

    assert [%{id: ^container_id, name: ^name, image_id: ^img_id}] =
             TestHelper.container_list(api_spec)

    %Schemas.Container{id: container_id2, name: name2, image_id: ^img_id} =
      container_succesfully_create(api_spec, "testcont2", %{})

    assert [%{id: ^container_id2, name: ^name2, image_id: ^img_id}, %{id: ^container_id}] =
             TestHelper.container_list(api_spec)

    %{id: ^container_id} = TestHelper.container_remove(api_spec, container_id)
    assert [%{id: ^container_id2}] = TestHelper.container_list(api_spec)

    %{id: ^container_id2} = TestHelper.container_remove(api_spec, container_id2)
    assert [] = TestHelper.container_list(api_spec)

    assert %{message: "no such container"} ==
             TestHelper.container_remove(api_spec, container_id2)
  end

  test "start and stop a container (using devfs)", %{api_spec: api_spec} do
    config = %{cmd: ["/bin/sleep", "10"]}

    {%Schemas.Container{id: container_id} = cont, exec_id} =
      TestHelper.container_start_attached(api_spec, "testcont", config)

    assert TestHelper.devfs_mounted(cont)

    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)

    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 1}}}
    refute TestHelper.devfs_mounted(cont)
  end

  test "start container without attaching to it", %{api_spec: api_spec} do
    %Schemas.Container{id: container_id} =
      container =
      container_succesfully_create(api_spec, "ws_test_container", %{
        image: "base",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    {:ok, exec_id} = Exec.create(container.id)

    assert [:not_attached] ==
             TestHelper.exec_start_sync(exec_id, %{attach: false, start_container: true})

    {:ok, ^container_id} = Container.remove(container_id)
  end

  test "start a container (using devfs), attach to it and receive output", %{api_spec: api_spec} do
    cmd_expected = ["/bin/echo", "test test"]

    %Schemas.Container{id: container_id, command: command} =
      container = container_succesfully_create(api_spec, "testcont", %{cmd: cmd_expected})

    assert cmd_expected == command

    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: true, start_container: true})

    assert_receive {:container, ^exec_id, {:jail_output, "test test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}, 5_000
    refute TestHelper.devfs_mounted(container)
  end

  test "start a container and force-stop it", %{api_spec: api_spec} do
    %Schemas.Container{id: container_id} =
      container_succesfully_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: false, start_container: true})

    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)

    refute Utils.is_container_running?(container_id)
  end

  test "start and stop a container with '/etc/rc' (using devfs)", %{
    api_spec: api_spec
  } do
    config = %{
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs", "exec.stop=\"/bin/sh /etc/rc.shutdown\""],
      user: "root"
    }

    {%Schemas.Container{id: container_id} = cont, exec_id} =
      TestHelper.container_start_attached(api_spec, "testcont", config)

    assert TestHelper.devfs_mounted(cont)
    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 1}}}
    assert not TestHelper.devfs_mounted(cont)
  end

  test "create container from non-existing image", %{api_spec: api_spec} do
    assert %{message: "no such image 'nonexisting'"} ==
             TestHelper.container_create(api_spec, "testcont", %{image: "nonexisting"})
  end

  test "start a container as non-root", %{api_spec: api_spec} do
    {_cont, exec_id} =
      TestHelper.container_start_attached(api_spec, "testcont", %{
        cmd: ["/usr/bin/id"],
        user: "ntpd"
      })

    assert_receive {:container, ^exec_id,
                    {:jail_output, "uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"}}

    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}
  end

  test "start a container with environment variables set", %{api_spec: api_spec} do
    config = %{
      cmd: ["/bin/sh", "-c", "printenv"],
      env: ["LOL=test", "LOOL=test2"],
      user: "root"
    }

    {_cont, exec_id} = TestHelper.container_start_attached(api_spec, "testcont", config)

    assert_receive {:container, ^exec_id, {:jail_output, "PWD=/\nLOOL=test2\nLOL=test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}
  end

  test "start container quickly several times to verify reproducibility", %{api_spec: api_spec} do
    container =
      container_succesfully_create(api_spec, "ws_test_container", %{
        image: "base",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    container_id = container.id
    :ok = start_n_attached_containers_and_receive_output(container.id, 20)
    {:ok, ^container_id} = Container.remove(container_id)
  end

  test "start a container with environment variables", %{api_spec: api_spec} do
    dockerfile = """
    FROM scratch
    ENV TEST=lol
    ENV TEST2="lool test"
    CMD /bin/sh -c "printenv"
    """

    config_image = %{
      context: "./",
      dockerfile: "tmp_dockerfile",
      tag: "test:latest"
    }

    TestHelper.create_tmp_dockerfile(dockerfile, "tmp_dockerfile")
    {image, _build_log} = TestHelper.image_valid_build(config_image)

    config = %{
      image: image.id,
      env: ["TEST3=loool"],
      cmd: ["/bin/sh", "-c", "printenv"]
    }

    {container, exec_id} = TestHelper.container_start_attached(api_spec, "testcont", config)

    assert_receive {:container, ^exec_id, {:jail_output, env_vars}}
    env_vars_set = String.trim(env_vars, "\n") |> String.split("\n") |> MapSet.new()
    expected_set = MapSet.new(["PWD=/", "TEST=lol", "TEST2=lool test", "TEST3=loool"])
    assert MapSet.equal?(env_vars_set, expected_set)

    Container.remove(container.id)
    Image.destroy(image.id)
  end

  test "start a container with environment variables and overwrite one of them", %{
    api_spec: api_spec
  } do
    dockerfile = """
    FROM scratch
    ENV TEST=lol
    ENV TEST2="lool test"
    CMD /bin/sh -c "printenv"
    """

    config_image = %{
      context: "./",
      dockerfile: "tmp_dockerfile",
      tag: "test:latest"
    }

    TestHelper.create_tmp_dockerfile(dockerfile, "tmp_dockerfile")
    {image, _build_log} = TestHelper.image_valid_build(config_image)

    config = %{
      image: image.id,
      env: ["TEST=new_value"],
      cmd: ["/bin/sh", "-c", "printenv"]
    }

    {container, exec_id} = TestHelper.container_start_attached(api_spec, "testcont", config)

    assert_receive {:container, ^exec_id, {:jail_output, env_vars}}
    env_vars_set = String.trim(env_vars, "\n") |> String.split("\n") |> MapSet.new()
    expected_set = MapSet.new(["PWD=/", "TEST=new_value", "TEST2=lool test"])
    assert MapSet.equal?(env_vars_set, expected_set)

    Container.remove(container.id)
    Image.destroy(image.id)
  end

  defp container_succesfully_create(api_spec, name, config) do
    %{id: container_id} = TestHelper.container_create(api_spec, name, config)
    MetaData.get_container(container_id)
  end

  defp start_n_attached_containers_and_receive_output(_container_id, 0) do
    :ok
  end

  defp start_n_attached_containers_and_receive_output(container_id, number_of_starts) do
    {:ok, exec_id} = Exec.create(container_id)
    stop_msg = "executable #{exec_id} and its container exited with exit-code 0"

    assert ["OK", "FreeBSD\n", stop_msg] ==
             TestHelper.exec_start_sync(exec_id, %{attach: true, start_container: true})

    start_n_attached_containers_and_receive_output(container_id, number_of_starts - 1)
  end
end
