defmodule ContainerTest do
  use Jocker.API.ConnCase
  alias Jocker.Engine.{Container, Image, Exec, Utils}

  @moduletag :capture_log

  setup do
    on_exit(fn ->
      Jocker.Engine.MetaData.list_containers()
      |> Enum.map(fn %{id: id} -> Container.destroy(id) end)
    end)

    :ok
  end

  test "create, destroy and list containers", %{
    api_spec: api_spec
  } do
    assert [] == TestHelper.container_list(api_spec)

    %Container{id: container_id, name: name, image_id: img_id} =
      TestHelper.container_create(api_spec, "testcont", %{})

    %Image{id: id} = Jocker.Engine.MetaData.get_image("base")
    assert id == img_id

    assert [%{id: ^container_id, name: ^name, image_id: ^img_id}] =
             TestHelper.container_list(api_spec)

    %Container{id: container_id2, name: name2, image_id: ^img_id} =
      TestHelper.container_create(api_spec, "testcont2", %{})

    assert [%{id: ^container_id2, name: ^name2, image_id: ^img_id}, %{id: ^container_id}] =
             TestHelper.container_list(api_spec)

    %{id: ^container_id} = TestHelper.container_destroy(api_spec, container_id)
    assert [%{id: ^container_id2}] = TestHelper.container_list(api_spec)

    %{id: ^container_id2} = TestHelper.container_destroy(api_spec, container_id2)
    assert [] = TestHelper.container_list(api_spec)

    assert %{message: "lol"} == TestHelper.container_destroy(api_spec, container_id2)
  end

  test "start and stop a container (using devfs)", %{api_spec: api_spec} do
    config = %{cmd: ["/bin/sleep", "10"]}

    {%Container{id: container_id} = cont, exec_id} =
      TestHelper.container_start_attached(api_spec, "testcont", config)

    assert TestHelper.devfs_mounted(cont)

    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)

    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}
    refute TestHelper.devfs_mounted(cont)
  end

  test "start a container (using devfs), attach to it and receive output", %{api_spec: api_spec} do
    cmd_expected = ["/bin/echo", "test test"]

    %Container{id: container_id, command: command} =
      container = TestHelper.container_create(api_spec, "testcont", %{cmd: cmd_expected})

    assert cmd_expected == command

    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: true, start_container: true})

    assert_receive {:container, ^exec_id, {:jail_output, "test test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}, 5_000
    refute TestHelper.devfs_mounted(container)
  end

  test "start a container and force-stop it", %{api_spec: api_spec} do
    %Container{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: false, start_container: true})

    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)

    refute Utils.is_container_running?(container_id)
  end

  test "start a second process in a container and receive output from it", %{
    # FIXME: Exec-test
    api_spec: api_spec
  } do
    %Container{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    {:ok, root_exec_id} = Exec.create(container_id)
    :ok = Exec.start(root_exec_id, %{attach: false, start_container: true})

    {:ok, exec_id} =
      Exec.create(%Jocker.API.Schemas.ExecConfig{
        container_id: container_id,
        cmd: ["/bin/echo", "test test"]
      })

    :ok = Exec.start(exec_id, %{attach: true, start_container: false})
    assert_receive {:container, ^exec_id, {:jail_output, "test test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, :jailed_process_exited}}

    stop_opts = %{stop_container: true, force_stop: false}
    assert {:ok, ^container_id} = Exec.stop(root_exec_id, stop_opts)
    refute Utils.is_container_running?(container_id)
  end

  test "start a second process in a container and terminate it using 'stop_container: false'", %{
    # FIXME: Exec-test?
    api_spec: api_spec
  } do
    %Container{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    {:ok, root_exec_id} = Exec.create(container_id)
    :ok = Exec.start(root_exec_id, %{attach: false, start_container: true})

    {:ok, exec_id} =
      Exec.create(%Jocker.API.Schemas.ExecConfig{
        container_id: container_id,
        cmd: ["/bin/sleep", "99"]
      })

    :ok = Exec.start(exec_id, %{attach: true, start_container: false})
    assert number_of_jailed_processes(container_id) == 2

    assert {:ok, "succesfully sent termination signal to executable"} =
             Exec.stop(exec_id, %{stop_container: false, force_stop: false})

    assert_receive {:container, ^exec_id, {:shutdown, :jailed_process_exited}}
    assert number_of_jailed_processes(container_id) == 1

    assert Utils.is_container_running?(container_id)

    assert {:ok, ^container_id} =
             Exec.stop(root_exec_id, %{stop_container: true, force_stop: false})

    refute Utils.is_container_running?(container_id)
  end

  test "start a second process in a container and terminate it using 'stop_container: true'", %{
    # FIXME: Exec-test?
    api_spec: api_spec
  } do
    %Container{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    {:ok, root_exec_id} = Exec.create(container_id)
    :ok = Exec.start(root_exec_id, %{attach: false, start_container: true})

    {:ok, exec_id} =
      Exec.create(%Jocker.API.Schemas.ExecConfig{
        container_id: container_id,
        cmd: ["/bin/sleep", "99"]
      })

    :ok = Exec.start(exec_id, %{attach: true, start_container: false})
    assert number_of_jailed_processes(container_id) == 2

    assert {:ok, ^container_id} = Exec.stop(exec_id, %{stop_container: true, force_stop: false})

    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}
    assert number_of_jailed_processes(container_id) == 0
    refute Utils.is_container_running?(container_id)
  end

  test "use execution instance created with container name instead of container id", %{
    # FIXME: Exec-test
    api_spec: api_spec
  } do
    %Container{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    {:ok, root_exec_id} = Exec.create("testcont")

    :ok = Exec.start(root_exec_id, %{attach: false, start_container: true})

    # seems like '/usr/sbin/jail' returns before the kernel reports it as running?
    :timer.sleep(500)
    assert Utils.is_container_running?(container_id)

    assert {:ok, container_id} ==
             Exec.stop(root_exec_id, %{stop_container: true, force_stop: false})

    refute Utils.is_container_running?(container_id)
  end

  test "cases where Exec.* should return errors (e.g., start a non-existing container and start non-existing exec-instance",
       # FIXME: Exec-test
       %{
         api_spec: api_spec
       } do
    %Container{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    assert {:error, "conntainer not found"} == Exec.create("nottestcont")

    {:ok, root_exec_id} = Exec.create(container_id)

    assert {:error, "could not find a execution instance matching 'wrongexecid'"} ==
             Exec.start("wrongexecid", %{attach: false, start_container: true})

    assert {:error, "cannot start container when 'start_container' is false."} ==
             Exec.start(root_exec_id, %{attach: false, start_container: false})

    :ok = Exec.start(root_exec_id, %{attach: false, start_container: true})

    assert {:error, "executable already started"} ==
             Exec.start(root_exec_id, %{attach: false, start_container: true})

    assert Utils.is_container_running?(container_id)

    {:ok, exec_id} =
      Exec.create(%Jocker.API.Schemas.ExecConfig{
        container_id: container_id,
        cmd: ["/bin/sleep", "99"]
      })

    assert {:ok, "execution instance not running, removing it anyway"} ==
             Exec.stop(exec_id, %{stop_container: true, force_stop: false})

    assert Utils.is_container_running?(container_id)
    assert Utils.is_container_running?(container_id)

    assert {:ok, container_id} ==
             Exec.stop(root_exec_id, %{stop_container: true, force_stop: false})
  end

  test "try to start a running executable", %{api_spec: api_spec} do
    # FIXME: Exec-test
    start_opts = %{start_container: true, attach: false}
    stop_opts = %{stop_container: true, force_stop: false}

    {%Container{id: container_id}, exec_id} =
      TestHelper.container_start_attached(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    assert {:error, "executable already started"} == Exec.start(exec_id, start_opts)
    assert {:ok, ^container_id} = Exec.stop(exec_id, stop_opts)
  end

  test "start and stop a container with '/etc/rc' (using devfs)", %{
    api_spec: api_spec
  } do
    config = %{
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs", "exec.stop=\"/bin/sh /etc/rc.shutdown\""],
      user: "root"
    }

    {%Container{id: container_id} = cont, exec_id} =
      TestHelper.container_start_attached(api_spec, "testcont", config)

    assert TestHelper.devfs_mounted(cont)
    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)
    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}
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

    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}
  end

  test "start a container with environment variables set", %{api_spec: api_spec} do
    config = %{
      cmd: ["/bin/sh", "-c", "printenv"],
      env: ["LOL=test", "LOOL=test2"],
      user: "root"
    }

    {_cont, exec_id} = TestHelper.container_start_attached(api_spec, "testcont", config)

    assert_receive {:container, ^exec_id, {:jail_output, "PWD=/\nLOOL=test2\nLOL=test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, :jail_stopped}}
  end

  test "start a container with environment variables", %{api_spec: api_spec} do
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

    {container, exec_id} = TestHelper.container_start_attached(api_spec, "testcont", config)

    assert_receive {:container, ^exec_id, {:jail_output, env_vars}}
    env_vars_set = String.trim(env_vars, "\n") |> String.split("\n") |> MapSet.new()
    expected_set = MapSet.new(["PWD=/", "TEST=lol", "TEST2=lool test", "TEST3=loool"])
    assert MapSet.equal?(env_vars_set, expected_set)

    Container.destroy(container.id)
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

    TestHelper.create_tmp_dockerfile(dockerfile, "tmp_dockerfile")
    {image, _messages} = TestHelper.build_and_return_image("./", "tmp_dockerfile", "test:latest")

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

    Container.destroy(container.id)
    Image.destroy(image.id)
  end

  defp number_of_jailed_processes(container_id) do
    case System.cmd("/bin/ps", ~w"--libxo json -J #{container_id}") do
      {jailed_processes, 0} ->
        %{"process-information" => %{"process" => processes}} = Jason.decode!(jailed_processes)
        length(processes)

      {_, _nonzero} ->
        0
    end
  end
end
