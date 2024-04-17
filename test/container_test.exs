defmodule ContainerTest do
  require Logger
  use Kleened.Test.ConnCase
  alias ExUnit.CaptureLog
  alias Kleened.Core.{Container, Exec, Utils, MetaData, OS}
  alias Kleened.API.Schemas

  @moduletag :capture_log

  setup %{host_state: state} do
    TestHelper.cleanup()

    on_exit(fn ->
      CaptureLog.capture_log(fn ->
        Logger.info("Cleaning up after test...")
        TestHelper.cleanup()
        TestHelper.compare_to_baseline_environment(state)
      end)
    end)

    :ok
  end

  test "create, remove and list containers", %{
    api_spec: api_spec
  } do
    assert [] == TestHelper.container_list(api_spec)

    %Schemas.Container{id: container_id, name: name, image_id: img_id} =
      container_succesfully_create(%{name: "testcont"})

    %Schemas.Image{id: id} = Kleened.Core.MetaData.get_image("FreeBSD:testing")
    assert id == img_id

    assert [%{id: ^container_id, name: ^name, image_id: ^img_id}] =
             TestHelper.container_list(api_spec)

    %Schemas.Container{id: container_id2, name: name2, image_id: ^img_id} =
      container_succesfully_create(%{name: "testcont2"})

    assert [%{id: ^container_id2, name: ^name2, image_id: ^img_id}, %{id: ^container_id}] =
             TestHelper.container_list(api_spec)

    %{id: ^container_id} = TestHelper.container_remove(api_spec, container_id)
    assert [%{id: ^container_id2}] = TestHelper.container_list(api_spec)

    %{id: ^container_id2} = TestHelper.container_remove(api_spec, container_id2)
    assert [] = TestHelper.container_list(api_spec)

    assert %{message: "no such container"} ==
             TestHelper.container_remove(api_spec, container_id2)
  end

  test "prune containers", %{
    api_spec: api_spec
  } do
    %Schemas.Container{id: container_id1} =
      container_succesfully_create(%{name: "testprune1", cmd: ["/bin/sleep", "10"]})

    %Schemas.Container{id: container_id2} =
      container_succesfully_create(%{name: "testprune2", cmd: ["/bin/sleep", "10"]})

    %Schemas.Container{id: container_id3} =
      container_succesfully_create(%{name: "testprune3", cmd: ["/bin/sleep", "10"]})

    {:ok, exec_id} = Exec.create(%Schemas.ExecConfig{container_id: container_id2})
    TestHelper.exec_valid_start(%{exec_id: exec_id, start_container: true, attach: false})

    :timer.sleep(1000)

    assert [^container_id1, ^container_id3] = TestHelper.container_prune(api_spec)

    assert [%{id: ^container_id2}] = TestHelper.container_list(api_spec)

    Container.stop(container_id2)
  end

  test "Inspect a container", %{api_spec: api_spec} do
    %Schemas.Container{} = container_succesfully_create(%{name: "testcontainer"})
    response = TestHelper.container_inspect_raw("notexist")
    assert response.status == 404
    response = TestHelper.container_inspect_raw("testcontainer")
    assert response.status == 200
    result = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert %{container: %{name: "testcontainer"}} = result
    assert_schema(result, "ContainerInspect", api_spec)
  end

  test "start and stop a container (using devfs)", %{api_spec: api_spec} do
    config = %{name: "testcont", cmd: ["/bin/sleep", "10"]}

    {%Schemas.Container{id: container_id} = cont, exec_id} =
      TestHelper.container_start_attached(api_spec, config)

    assert TestHelper.devfs_mounted(cont)

    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)

    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 1}}}
    refute TestHelper.devfs_mounted(cont)
  end

  test "start container without attaching to it", %{api_spec: api_spec} do
    %Schemas.Container{id: container_id} =
      container =
      container_succesfully_create(%{
        name: "ws_test_container",
        image: "FreeBSD:testing",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    {:ok, exec_id} = Exec.create(container.id)
    config = %{exec_id: exec_id, attach: false, start_container: true}

    assert {"succesfully started execution instance in detached mode", ""} ==
             TestHelper.exec_valid_start(config)

    :timer.sleep(100)
    assert %{id: container_id} == TestHelper.container_remove(api_spec, container_id)
  end

  test "start a container (using devfs), attach to it and receive output" do
    cmd_expected = ["/bin/echo", "test test"]

    %Schemas.Container{id: container_id, cmd: cmd} =
      container = container_succesfully_create(%{name: "testcont", cmd: cmd_expected})

    assert cmd_expected == cmd

    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: true, start_container: true})

    assert_receive {:container, ^exec_id, {:jail_output, "test test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}, 5_000
    refute TestHelper.devfs_mounted(container)
  end

  test "start a container and force-stop it", %{api_spec: api_spec} do
    %Schemas.Container{id: container_id} =
      container_succesfully_create(%{name: "testcont", cmd: ["/bin/sleep", "10"]})

    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: false, start_container: true})

    :timer.sleep(500)
    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)

    refute Utils.is_container_running?(container_id)
  end

  test "start and stop a container with '/etc/rc' (using devfs)", %{
    api_spec: api_spec
  } do
    config = %{
      name: "testcont",
      cmd: ["/bin/sleep", "10"],
      jail_param: ["mount.devfs", "exec.stop=\"/bin/sh /etc/rc.shutdown\""],
      user: "root"
    }

    {%Schemas.Container{id: container_id} = cont, exec_id} =
      TestHelper.container_start_attached(api_spec, config)

    assert TestHelper.devfs_mounted(cont)
    assert %{id: ^container_id} = TestHelper.container_stop(api_spec, container_id)
    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 1}}}
    assert not TestHelper.devfs_mounted(cont)
  end

  test "making nullfs-mounts into a container" do
    File.rm("/mnt/testing_mounts.txt")
    mount_path = "/kleene_nullfs_testing"

    # RW mount
    config = %{
      name: "testcont",
      cmd: ["/usr/bin/touch", "#{mount_path}/testing_mounts.txt"],
      mounts: [%{type: "nullfs", source: "/mnt", destination: mount_path}],
      user: "root"
    }

    {container_id, _, process_output} = TestHelper.container_valid_run(config)
    assert process_output == []
    file_path = "/zroot/kleene/container/#{container_id}/#{mount_path}/testing_mounts.txt"
    assert File.read(file_path) == {:error, :enoent}
    file_path = "/mnt/testing_mounts.txt"
    assert File.read(file_path) == {:ok, ""}

    # Read-only mount
    config = %{
      name: "testcont",
      cmd: ["/usr/bin/touch", "#{mount_path}/testing_mounts.txt"],
      mounts: [%{type: "nullfs", source: "/mnt/", destination: mount_path, read_only: true}],
      user: "root",
      expected_exit_code: 1
    }

    {_, _, output} = TestHelper.container_valid_run(config)

    expected_output = """
    touch: /kleene_nullfs_testing/testing_mounts.txt: Read-only file system
    jail: /usr/bin/env /usr/bin/touch /kleene_nullfs_testing/testing_mounts.txt: failed
    """

    assert Enum.join(output) == expected_output
  end

  test "mounting a volume into a container with rw permissions", %{
    api_spec: api_spec
  } do
    volume = TestHelper.volume_create(api_spec, "volume-mounting-test")
    mount_path = "/kleene_volume_testing"

    # RW mount
    config = %{
      name: "testcont",
      cmd: ["/usr/bin/touch", "#{mount_path}/testing_mounts.txt"],
      mounts: [%{type: "volume", source: volume.name, destination: mount_path}],
      user: "root"
    }

    {container_id, _, process_output} = TestHelper.container_valid_run(config)
    assert process_output == []
    file_path = "/zroot/kleene/container/#{container_id}/#{mount_path}/testing_mounts.txt"
    assert File.read(file_path) == {:error, :enoent}
    file_path = "/zroot/kleene/volumes/#{volume.name}/testing_mounts.txt"
    assert File.read(file_path) == {:ok, ""}
    TestHelper.volume_remove(api_spec, volume.name)
  end

  test "mounting a volume into a container with read-only permissions", %{
    api_spec: api_spec
  } do
    volume = TestHelper.volume_create(api_spec, "volume-mounting-test")
    mount_path = "/kleene_volume_testing"

    # Read-only mount
    config = %{
      name: "testcont",
      cmd: ["/usr/bin/touch", "#{mount_path}/testing_mounts.txt"],
      mounts: [%{type: "volume", source: volume.name, destination: mount_path, read_only: true}],
      user: "root",
      expected_exit_code: 1
    }

    {_, _, output} = TestHelper.container_valid_run(config)

    expected_output = """
    touch: /kleene_volume_testing/testing_mounts.txt: Read-only file system
    jail: /usr/bin/env /usr/bin/touch /kleene_volume_testing/testing_mounts.txt: failed
    """

    assert Enum.join(output) == expected_output

    TestHelper.volume_remove(api_spec, volume.name)
  end

  test "mounting an empty volume into a non-empty directory of the container", %{
    api_spec: api_spec
  } do
    volume = TestHelper.volume_create(api_spec, "volume-populate-test")
    mount_path = "/etc/defaults"

    # RW mount
    config = %{
      name: "testcont",
      cmd: ["/usr/bin/touch", "#{mount_path}/test_volume_mount"],
      mounts: [%{type: "volume", source: volume.name, destination: mount_path}],
      user: "root"
    }

    {_container_id, _, process_output} = TestHelper.container_valid_run(config)
    assert process_output == []
    {output, 0} = OS.cmd(~w"/bin/ls #{volume.mountpoint}")

    assert output ==
             "bluetooth.device.conf\ndevfs.rules\nperiodic.conf\nrc.conf\ntest_volume_mount\n"

    TestHelper.volume_remove(api_spec, volume.name)
  end

  test "mounting a non-existing volume into a container" do
    mount_path = "/kleene_volume_testing"
    volume_name = "will-be-created"

    config = %{
      name: "testcont",
      cmd: ["/usr/bin/touch", "#{mount_path}/testing_mounts.txt"],
      mounts: [%{type: "volume", source: volume_name, destination: mount_path}],
      user: "root"
    }

    {container_id, _, process_output} = TestHelper.container_valid_run(config)
    assert process_output == []
    file_path = "/zroot/kleene/container/#{container_id}/#{mount_path}/testing_mounts.txt"
    assert File.read(file_path) == {:error, :enoent}
    file_path = "/zroot/kleene/volumes/#{volume_name}/testing_mounts.txt"
    assert File.read(file_path) == {:ok, ""}
  end

  test "updating a container", %{
    api_spec: api_spec
  } do
    %Schemas.Container{id: container_id} =
      container =
      container_succesfully_create(%{
        name: "testcontainer",
        user: "ntpd",
        cmd: ["/bin/sleep", "10"],
        env: ["TESTVAR=testval"],
        jail_param: ["allow.raw_sockets=true"]
      })

    config_nil = %{
      name: nil,
      user: nil,
      cmd: nil,
      env: nil,
      jail_param: nil
    }

    # Test a "nil-update"
    %{id: ^container_id} = TestHelper.container_update(api_spec, container_id, config_nil)
    %{container: container_upd} = TestHelper.container_inspect(container_id)
    assert container_upd == container

    # Test changing name
    %{id: ^container_id} =
      TestHelper.container_update(api_spec, container_id, %{config_nil | name: "testcontupd"})

    %{container: container_upd} = TestHelper.container_inspect(container_id)

    assert container_upd.name == "testcontupd"

    # Test changing env and cmd
    %{id: ^container_id} =
      TestHelper.container_update(api_spec, container_id, %{
        config_nil
        | env: ["TESTVAR=testval2"],
          cmd: ["/bin/sleep", "20"]
      })

    %{container: container_upd} = TestHelper.container_inspect(container_id)
    assert container_upd.env == ["TESTVAR=testval2"]
    assert container_upd.cmd == ["/bin/sleep", "20"]

    # Test changing jail-param
    %{id: ^container_id} =
      TestHelper.container_update(api_spec, container_id, %{
        config_nil
        | user: "root",
          jail_param: ["allow.raw_sockets=false"]
      })

    %{container: container_upd} = TestHelper.container_inspect(container_id)

    assert container_upd.jail_param == ["allow.raw_sockets=false"]
    assert container_upd.user == "root"
  end

  test "updating on a running container", %{api_spec: api_spec} do
    %Schemas.Container{id: container_id} =
      container_succesfully_create(%{
        name: "testcontainer",
        user: "root",
        cmd: ["/bin/sh", "/etc/rc"],
        jail_param: ["mount.devfs"]
      })

    config_nil = %{
      name: nil,
      user: nil,
      cmd: nil,
      env: nil,
      jail_param: nil
    }

    # Test changing a jail-param that can be modfied while running
    {:ok, exec_id} = Exec.create(%Schemas.ExecConfig{container_id: container_id})

    TestHelper.exec_valid_start(%{exec_id: exec_id, start_container: true, attach: true})

    %{id: ^container_id} =
      TestHelper.container_update(api_spec, container_id, %{
        config_nil
        | jail_param: ["mount.devfs", "host.hostname=testing.local"]
      })

    %{container: container_upd} = TestHelper.container_inspect(container_id)
    assert container_upd.jail_param == ["mount.devfs", "host.hostname=testing.local"]

    {:ok, exec_id} =
      Exec.create(%Kleened.API.Schemas.ExecConfig{
        container_id: container_id,
        cmd: ["/bin/hostname"]
      })

    {_closing_msg, output} =
      TestHelper.exec_valid_start(%{
        exec_id: exec_id,
        attach: true,
        start_container: false
      })

    assert output == ["testing.local\n"]

    assert %{
             message:
               "an error ocurred while updating the container: '/usr/sbin/jail' returned non-zero exitcode 1 when attempting to modify the container 'jail: vnet cannot be changed after creation\n'"
           } ==
             TestHelper.container_update(api_spec, container_id, %{
               config_nil
               | jail_param: ["vnet"]
             })

    Container.stop(container_id)
  end

  test "create container from non-existing image" do
    assert %{message: "no such image 'nonexisting'"} ==
             TestHelper.container_create(%{name: "testcont", image: "nonexisting"})
  end

  test "start a container as non-root", %{api_spec: api_spec} do
    {_cont, exec_id} =
      TestHelper.container_start_attached(api_spec, %{
        name: "testcont",
        cmd: ["/usr/bin/id"],
        user: "ntpd"
      })

    assert_receive {:container, ^exec_id,
                    {:jail_output, "uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"}}

    assert_receive {:container, ^exec_id, {:shutdown, {:jail_stopped, 0}}}
  end

  test "jail parameters 'mount.devfs' and 'exec.clean' defaults can be replaced with jailparams" do
    # Override mount.devfs=true with mount.nodevfs
    config =
      container_config(%{
        jail_param: ["mount.nodevfs"],
        cmd: ["/bin/sh", "-c", "ls /dev"]
      })

    # With mount.devfs=true you get:
    # ["fd\nnull\npts\nrandom\nstderr\nstdin\nstdout\nurandom\nzero\nzfs\n"]
    assert {_, _, []} = TestHelper.container_valid_run(config)

    # Override mount.devfs=true/exec.clean=true with mount.devfs=false/exec.noclean
    config =
      container_config(%{
        jail_param: ["mount.devfs=false", "exec.noclean"],
        cmd: ["/bin/sh", "-c", "ls /dev && printenv"]
      })

    {_, _, output} = TestHelper.container_valid_run(config)
    environment = TestHelper.from_environment_output(output)
    assert MapSet.member?(environment, "EMU=beam")

    # Override mount.devfs=true with mount.devfs=true
    config =
      container_config(%{
        jail_param: ["mount.devfs"],
        cmd: ["/bin/sh", "-c", "ls /dev"]
      })

    {_, _, output} = TestHelper.container_valid_run(config)
    assert ["fd\nnull\npts\nrandom\nstderr\nstdin\nstdout\nurandom\nzero\nzfs\n"] == output

    # Override exec.clean=true with exec.clean=true
    config =
      container_config(%{
        jail_param: ["exec.clean=true"],
        cmd: ["/bin/sh", "-c", "printenv"]
      })

    {_, _, output} = TestHelper.container_valid_run(config)
    environment = TestHelper.from_environment_output(output)
    assert environment == TestHelper.jail_environment([])
  end

  test "test that jail-param 'exec.jail_user' overrides ContainerConfig{user:}" do
    config =
      container_config(%{
        jail_param: ["exec.jail_user=ntpd"],
        user: "root",
        cmd: ["/usr/bin/id"]
      })

    {_, _, output} = TestHelper.container_valid_run(config)
    assert ["uid=123(ntpd) gid=123(ntpd) groups=123(ntpd)\n"] == output
  end

  test "start a container with environment variables set" do
    config = %{
      image: "FreeBSD:testing",
      name: "testcont",
      cmd: ["/bin/sh", "-c", "printenv"],
      env: ["LOL=test", "LOOL=test2"],
      user: "root",
      attach: true
    }

    {_, _, output} = TestHelper.container_valid_run(config)
    TestHelper.compare_environment_output(output, ["LOOL=test2", "LOL=test"])
  end

  test "start a container with environment variables" do
    dockerfile = """
    FROM FreeBSD:testing
    ENV TEST=lol
    ENV TEST2="lool test"
    CMD printenv
    """

    TestHelper.create_tmp_dockerfile(dockerfile, "tmp_dockerfile")

    {image, _build_log} =
      TestHelper.image_valid_build(%{
        context: "./",
        dockerfile: "tmp_dockerfile",
        tag: "test:latest"
      })

    config =
      container_config(%{
        image: image.id,
        env: ["TEST3=loool"]
      })

    {_, _, output} = TestHelper.container_valid_run(config)

    TestHelper.compare_environment_output(output, [
      "TEST=lol",
      "TEST2=lool test",
      "TEST3=loool"
    ])
  end

  test "start a container with environment variables and overwrite one of them" do
    dockerfile = """
    FROM FreeBSD:testing
    ENV TEST=lol
    ENV TEST2="lool test"
    CMD /bin/sh -c "printenv"
    """

    TestHelper.create_tmp_dockerfile(dockerfile, "tmp_dockerfile")

    {image, _build_log} =
      TestHelper.image_valid_build(%{
        context: "./",
        dockerfile: "tmp_dockerfile",
        tag: "test:latest"
      })

    config =
      container_config(%{
        image: image.id,
        env: ~w"TEST=new_value"
      })

    {_, _, output} = TestHelper.container_valid_run(config)
    TestHelper.compare_environment_output(output, ["TEST=new_value", "TEST2=lool test"])
  end

  test "try to remove a running container", %{api_spec: api_spec} do
    config = %{
      name: "remove_while_running",
      image: "FreeBSD:testing",
      user: "root",
      cmd: ~w"/bin/sh /etc/rc",
      attach: true
    }

    {container_id, _, _} = TestHelper.container_valid_run(config)

    assert %{message: "you cannot remove a running container"} ==
             TestHelper.container_remove(api_spec, container_id)

    Container.stop(container_id)
  end

  test "try to remove a container twice", %{api_spec: api_spec} do
    config = %{
      name: "remove_while_running",
      image: "FreeBSD:testing",
      user: "root",
      cmd: ~w"echo testing",
      attach: true
    }

    {container_id, _, _} = TestHelper.container_valid_run(config)

    assert %{id: container_id} ==
             TestHelper.container_remove(api_spec, container_id)

    assert %{message: "no such container"} ==
             TestHelper.container_remove(api_spec, container_id)
  end

  test "containers with '--restart on-startup' will be started when kleened starts" do
    TestHelper.network_create(%{
      name: "testnet",
      subnet: "172.19.0.0/16",
      gateway: "<auto>",
      type: "bridge"
    })

    config =
      container_config(%{
        name: "test-restart1",
        jail_param: ["mount.nodevfs"],
        cmd: ["/bin/sleep", "10"],
        network_driver: "ipnet",
        network: "testnet",
        restart_policy: "on-startup"
      })

    %Schemas.Container{id: container_id1} =
      container_succesfully_create(
        Map.merge(config, %{name: "test-restart1", network_driver: "ipnet"})
      )

    %Schemas.Container{id: container_id2} =
      container_succesfully_create(
        Map.merge(config, %{name: "test-restart2", network_driver: "vnet"})
      )

    Application.stop(:kleened)
    assert {"", 0} == OS.shell("ifconfig kleene0 destroy")

    Application.start(:kleened)

    :timer.sleep(200)

    # Fails because running is not used!
    %{container: %{running: true}} = TestHelper.container_inspect(container_id1)
    %{container: %{running: true}} = TestHelper.container_inspect(container_id2)

    assert {_, 0} = OS.shell("ifconfig kleene0")

    cmd = ["/bin/sh", "-c", "host -W 1 freebsd.org 1.1.1.1"]

    {:ok, exec_id} = Exec.create(%Schemas.ExecConfig{container_id: container_id1, cmd: cmd})

    {_closing_msg, [process_output]} =
      TestHelper.exec_valid_start(%Schemas.ExecStartConfig{
        exec_id: exec_id,
        attach: true,
        start_container: false
      })

    assert String.contains?(process_output, "freebsd.org has address 96.47.72.84")

    {:ok, exec_id} = Exec.create(%Schemas.ExecConfig{container_id: container_id2, cmd: cmd})

    {_closing_msg, [process_output]} =
      TestHelper.exec_valid_start(%Schemas.ExecStartConfig{
        exec_id: exec_id,
        attach: true,
        start_container: false
      })

    assert String.contains?(process_output, "freebsd.org has address 96.47.72.84")

    Container.stop(container_id1)
    Container.stop(container_id2)
  end

  test "containers with '--persist' will not be pruned", %{api_spec: api_spec} do
    %Schemas.Container{id: container_id1} =
      container_succesfully_create(%{name: "testprune1", cmd: ["/bin/sleep", "10"]})

    %Schemas.Container{id: container_id2} =
      container_succesfully_create(%{
        name: "testprune2",
        cmd: ["/bin/sleep", "10"],
        persist: true
      })

    %Schemas.Container{id: container_id3} =
      container_succesfully_create(%{name: "testprune3", cmd: ["/bin/sleep", "10"]})

    assert [^container_id1, ^container_id3] = TestHelper.container_prune(api_spec)

    assert [%{id: ^container_id2}] = TestHelper.container_list(api_spec)

    Container.stop(container_id2)
  end

  test "start container quickly several times to verify reproducibility" do
    container =
      container_succesfully_create(%{
        name: "ws_test_container",
        image: "FreeBSD:testing",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    container_id = container.id
    :ok = start_n_attached_containers_and_receive_output(container.id, 20)
    {:ok, ^container_id} = Container.remove(container_id)
  end

  defp container_config(config) do
    defaults = %{
      name: "container_testing",
      image: "FreeBSD:testing",
      user: "root",
      attach: true
    }

    Map.merge(defaults, config)
  end

  defp container_succesfully_create(config) do
    %{id: container_id} = TestHelper.container_create(config)
    MetaData.get_container(container_id)
  end

  defp start_n_attached_containers_and_receive_output(_container_id, 0) do
    :ok
  end

  defp start_n_attached_containers_and_receive_output(container_id, number_of_starts) do
    {:ok, exec_id} = Exec.create(container_id)
    stop_msg = "executable #{exec_id} and its container exited with exit-code 0"

    assert {stop_msg, ["FreeBSD\n"]} ==
             TestHelper.exec_valid_start(%{exec_id: exec_id, attach: true, start_container: true})

    start_n_attached_containers_and_receive_output(container_id, number_of_starts - 1)
  end
end
