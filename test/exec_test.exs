defmodule ExecTest do
  require Logger
  use Jocker.API.ConnCase
  alias Jocker.Engine.{Container, Exec, Utils, Network}
  alias Jocker.API.Schemas

  @moduletag :capture_log

  setup do
    {:ok, %Schemas.Network{name: "default"} = testnet} =
      Network.create(%Schemas.NetworkConfig{
        name: "default",
        subnet: "192.168.83.0/24",
        ifname: "jocker1",
        driver: "loopback"
      })

    on_exit(fn ->
      Jocker.Engine.Network.remove(testnet.id)

      Jocker.Engine.MetaData.list_containers()
      |> Enum.map(fn %{id: id} -> Container.remove(id) end)
    end)

    :ok
  end

  test "attach to a container and receive some output from it", %{api_spec: api_spec} do
    %{id: container_id} =
      TestHelper.container_create(api_spec, "test_container1", %{cmd: ["/bin/sh", "-c", "uname"]})

    {:ok, exec_id} = Exec.create(container_id)
    stop_msg = "executable #{exec_id} stopped"

    assert ["OK", "FreeBSD\n", stop_msg] ==
             TestHelper.exec_start_sync(exec_id, %{attach: true, start_container: true})

    {:ok, ^container_id} = Container.remove(container_id)
  end

  test "start a second process in a container and receive output from it", %{
    api_spec: api_spec
  } do
    %{id: container_id} =
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
    api_spec: api_spec
  } do
    %{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    %{id: root_exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    {:ok, root_conn} =
      TestHelper.exec_start(root_exec_id, %{attach: false, start_container: true})

    assert [:not_attached] == TestHelper.receive_frames(root_conn)

    %{id: exec_id} =
      TestHelper.exec_create(api_spec, %{
        container_id: container_id,
        cmd: ["/bin/sleep", "99"]
      })

    {:ok, conn} = TestHelper.exec_start(exec_id, %{attach: true, start_container: false})
    assert {:text, "OK"} == TestHelper.receive_frame(conn)
    assert number_of_jailed_processes(container_id) == 2

    assert %{id: exec_id} ==
             TestHelper.exec_stop(api_spec, exec_id, %{stop_container: false, force_stop: true})

    error_msg = "#{exec_id} has exited"
    assert [error_msg] == TestHelper.receive_frames(conn)

    assert number_of_jailed_processes(container_id) == 1

    assert Utils.is_container_running?(container_id)

    assert %{id: root_exec_id} ==
             TestHelper.exec_stop(api_spec, root_exec_id, %{
               stop_container: true,
               force_stop: false
             })

    refute Utils.is_container_running?(container_id)
  end

  test "start a second process in a container and terminate it using 'stop_container: true'", %{
    api_spec: api_spec
  } do
    %{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    %{id: root_exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    assert [:not_attached] ==
             TestHelper.exec_start_sync(root_exec_id, %{attach: false, start_container: true})

    %{id: exec_id} =
      TestHelper.exec_create(api_spec, %{
        container_id: container_id,
        cmd: ["/bin/sleep", "11"]
      })

    {:ok, conn} = TestHelper.exec_start(exec_id, %{attach: true, start_container: false})
    assert {:text, "OK"} == TestHelper.receive_frame(conn)

    assert number_of_jailed_processes(container_id) == 2

    assert %{id: ^exec_id} =
             TestHelper.exec_stop(api_spec, exec_id, %{
               stop_container: true,
               force_stop: false
             })

    msg = "executable #{exec_id} stopped"
    assert [msg] == TestHelper.receive_frames(conn)
    assert number_of_jailed_processes(container_id) == 0
    refute Utils.is_container_running?(container_id)
  end

  test "use execution instance created with container name instead of container id", %{
    api_spec: api_spec
  } do
    %{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    %{id: exec_id} = TestHelper.exec_create(api_spec, %{container_id: "testcont"})

    assert [:not_attached] ==
             TestHelper.exec_start_sync(exec_id, %{attach: false, start_container: true})

    # seems like '/usr/sbin/jail' returns before the kernel reports it as running?
    :timer.sleep(500)
    assert Utils.is_container_running?(container_id)

    assert %{id: exec_id} ==
             TestHelper.exec_stop(api_spec, exec_id, %{stop_container: true, force_stop: false})

    refute Utils.is_container_running?(container_id)
  end

  test "cases where Exec.* should return errors (e.g., start a non-existing container and start non-existing exec-instance",
       %{
         api_spec: api_spec
       } do
    {:error, "invalid value/missing parameter(s)"} =
      TestHelper.exec_start("nonexisting", %{attach: "mustbeboolean", start_container: true})

    {:error, "invalid value/missing parameter(s)"} =
      TestHelper.initialize_websocket(
        "/exec/nonexisting/start?nonexisting_param=true&start_container=true"
      )

    %{id: container_id} =
      TestHelper.container_create(api_spec, "testcont", %{cmd: ["/bin/sleep", "10"]})

    assert %{message: "conntainer not found"} ==
             TestHelper.exec_create(api_spec, %{container_id: "nottestcont"})

    %{id: root_exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    assert [
             "ERROR:could not find a execution instance matching 'wrongexecid'",
             "Failed to execute command."
           ] ==
             TestHelper.exec_start_sync("wrongexecid", %{attach: false, start_container: true})

    assert [
             "ERROR:cannot start container when 'start_container' is false.",
             "Failed to execute command."
           ] ==
             TestHelper.exec_start_sync(root_exec_id, %{attach: false, start_container: false})

    assert [:not_attached] ==
             TestHelper.exec_start_sync(root_exec_id, %{attach: false, start_container: true})

    assert ["ERROR:executable already started", "Failed to execute command."] ==
             TestHelper.exec_start_sync(root_exec_id, %{attach: false, start_container: true})

    assert Utils.is_container_running?(container_id)

    %{id: exec_id} =
      TestHelper.exec_create(api_spec, %{
        container_id: container_id,
        cmd: ["/bin/sleep", "99"]
      })

    assert %{id: exec_id} ==
             TestHelper.exec_stop(api_spec, exec_id, %{stop_container: true, force_stop: false})

    assert Utils.is_container_running?(container_id)

    assert %{id: root_exec_id} ==
             TestHelper.exec_stop(api_spec, root_exec_id, %{
               stop_container: true,
               force_stop: false
             })

    assert %{message: "no such container"} ==
             TestHelper.exec_stop(api_spec, root_exec_id, %{
               stop_container: true,
               force_stop: false
             })

    refute Utils.is_container_running?(container_id)
    {:ok, ^container_id} = Container.remove(container_id)
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
