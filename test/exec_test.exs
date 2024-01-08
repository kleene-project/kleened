defmodule ExecTest do
  require Logger
  use Kleened.Test.ConnCase
  alias Kleened.Core.{Container, Exec, Utils, Network}
  alias Kleened.API.Schemas
  alias Schemas.WebSocketMessage, as: Message

  @moduletag :capture_log

  setup do
    TestHelper.cleanup()

    {:ok, %Schemas.Network{name: "default"}} =
      Network.create(%Schemas.NetworkConfig{
        name: "default",
        subnet: "192.168.83.0/24",
        ifname: "kleene1",
        driver: "loopback"
      })

    on_exit(fn ->
      Logger.info("Cleaning up after test...")
      TestHelper.cleanup()
    end)

    :ok
  end

  test "attach to a container and receive some output from it" do
    %{id: container_id} =
      TestHelper.container_create(%{
        name: "test_container1",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    {:ok, exec_id} = Exec.create(container_id)

    stop_msg = "executable #{exec_id} and its container exited with exit-code 0"

    assert {stop_msg, ["FreeBSD\n"]} ==
             TestHelper.exec_valid_start(%{exec_id: exec_id, attach: true, start_container: true})

    {:ok, ^container_id} = Container.remove(container_id)
  end

  test "start a second process in a container and receive output from it" do
    %{id: container_id} =
      TestHelper.container_create(%{name: "testcont", cmd: ["/bin/sleep", "10"]})

    {:ok, root_exec_id} = Exec.create(container_id)
    :ok = Exec.start(root_exec_id, %{attach: false, start_container: true})

    {:ok, exec_id} =
      Exec.create(%Kleened.API.Schemas.ExecConfig{
        container_id: container_id,
        cmd: ["/bin/echo", "test test"]
      })

    :timer.sleep(100)
    :ok = Exec.start(exec_id, %{attach: true, start_container: false})
    assert_receive {:container, ^exec_id, {:jail_output, "test test\n"}}
    assert_receive {:container, ^exec_id, {:shutdown, {:jailed_process_exited, 0}}}

    stop_opts = %{stop_container: true, force_stop: false}
    assert {:ok, ^container_id} = Exec.stop(root_exec_id, stop_opts)
    refute Utils.is_container_running?(container_id)
  end

  test "start a second process in a container and terminate it using 'stop_container: false'", %{
    api_spec: api_spec
  } do
    %{id: container_id} =
      TestHelper.container_create(%{name: "testcont", cmd: ["/bin/sleep", "10"]})

    %{id: root_exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    {:ok, _stream_ref, root_conn} =
      TestHelper.exec_start(root_exec_id, %{attach: false, start_container: true})

    closing_msg =
      {1001,
       %Message{
         message: "succesfully started execution instance in detached mode",
         msg_type: "closing"
       }}

    assert [closing_msg] == TestHelper.receive_frames(root_conn)

    %{id: exec_id} =
      TestHelper.exec_create(api_spec, %{
        container_id: container_id,
        cmd: ["/bin/sleep", "99"]
      })

    {:ok, _stream_ref, conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: false})

    assert number_of_jailed_processes(container_id) == 2

    assert %{id: exec_id} ==
             TestHelper.exec_stop(api_spec, exec_id, %{stop_container: false, force_stop: true})

    error_msg =
      {1000, %Message{message: "#{exec_id} has exited with exit-code 137", msg_type: "closing"}}

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
      TestHelper.container_create(%{name: "testcont", cmd: ["/bin/sleep", "10"]})

    %{id: root_exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    config = %{exec_id: root_exec_id, attach: false, start_container: true}

    assert "succesfully started execution instance in detached mode" ==
             TestHelper.exec_valid_start(config)

    %{id: exec_id} =
      TestHelper.exec_create(api_spec, %{
        container_id: container_id,
        cmd: ["/bin/sleep", "11"]
      })

    {:ok, _stream_ref, conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: false})

    :timer.sleep(500)
    assert number_of_jailed_processes(container_id) == 2

    assert %{id: ^exec_id} =
             TestHelper.exec_stop(api_spec, exec_id, %{
               stop_container: true,
               force_stop: false
             })

    msg = "executable #{exec_id} and its container exited with exit-code 143"

    assert [{1000, %Message{message: msg, msg_type: "closing"}}] ==
             TestHelper.receive_frames(conn)

    assert number_of_jailed_processes(container_id) == 0
    refute Utils.is_container_running?(container_id)
  end

  test "Create a exec instance that allocates a pseudo-TTY", %{
    api_spec: api_spec
  } do
    %{id: container_id} = TestHelper.container_create(%{name: "testcont", cmd: ["/usr/bin/tty"]})

    # Start a process without attaching a PTY
    %{id: exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    {:ok, _stream_ref, conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: true})

    {:text, msg} = TestHelper.receive_frame(conn)
    assert <<"not a tty\n", _rest::binary>> = msg

    # Start a process with a PTY attach
    %{id: exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id, tty: true})

    {:ok, _stream_ref, conn} =
      TestHelper.exec_start(exec_id, %{attach: true, start_container: true})

    {:text, msg} = TestHelper.receive_frame(conn)
    assert <<"/dev/pts/", _rest::binary>> = msg
  end

  test "Create an interactive exec instance (allocatiing a pseudo-TTY)", %{
    api_spec: api_spec
  } do
    %{id: container_id} = TestHelper.container_create(%{name: "testcont", cmd: ["/bin/sh"]})

    # Start a process with a PTY attach
    %{id: exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id, tty: true})
    start_config = %{attach: true, start_container: true}
    {:ok, stream_ref, conn} = TestHelper.exec_start(exec_id, start_config)

    assert {:text, "# "} == TestHelper.receive_frame(conn)
    TestHelper.send_data(conn, stream_ref, "pwd && exit\r\n")
    frames = TestHelper.receive_frames(conn)

    {last_frame, frames} = List.pop_at(frames, -1)
    msg = "executable #{exec_id} and its container exited with exit-code 0"
    assert {1000, %Message{msg_type: "closing", message: msg, data: ""}} == last_frame
    frames_as_string = Enum.join(frames, "")

    assert "pwd && exit\r\n/root\r\n" == frames_as_string
  end

  test "use execution instance created with container name instead of container id", %{
    api_spec: api_spec
  } do
    %{id: container_id} =
      TestHelper.container_create(%{name: "testcont", cmd: ["/bin/sleep", "10"]})

    %{id: exec_id} = TestHelper.exec_create(api_spec, %{container_id: "testcont"})

    assert "succesfully started execution instance in detached mode" ==
             TestHelper.exec_valid_start(%{exec_id: exec_id, attach: false, start_container: true})

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
    frames =
      TestHelper.exec_start_raw(%{
        exec_id: "nonexisting",
        attach: "mustbeboolean",
        start_container: true
      })

    assert [{1002, %Message{msg_type: "error", message: msg}}] = frames
    assert "invalid parameters: Invalid boolean. Got: string" == msg

    frames =
      TestHelper.exec_start_raw(%{
        exec_id: "nonexisting",
        nonexisting_param: true,
        start_container: true
      })

    assert [{1002, %Message{msg_type: "error", message: msg}}] = frames
    assert "invalid parameters: Missing field: attach" == msg

    %{id: container_id} =
      TestHelper.container_create(%{name: "testcont", cmd: ["/bin/sleep", "10"]})

    assert %{message: "container not found"} ==
             TestHelper.exec_create(api_spec, %{container_id: "nottestcont"})

    %{id: root_exec_id} = TestHelper.exec_create(api_spec, %{container_id: container_id})

    assert [
             "error: could not find a execution instance matching 'wrongid'",
             {1011, %Message{message: "error starting exec instance", msg_type: "error"}}
           ] =
             TestHelper.exec_start_raw(%{exec_id: "wrongid", attach: false, start_container: true})

    assert [
             "error: cannot start container when 'start_container' is false.",
             {1011, %Message{message: "error starting exec instance", msg_type: "error"}}
           ] =
             TestHelper.exec_start_raw(%{
               exec_id: root_exec_id,
               attach: false,
               start_container: false
             })

    assert [{1001, %Message{message: msg, msg_type: "closing"}}] =
             TestHelper.exec_start_raw(%{
               exec_id: root_exec_id,
               attach: false,
               start_container: true
             })

    assert msg == "succesfully started execution instance in detached mode"

    assert [
             "error: executable already started",
             {1011, %Message{message: "error starting exec instance", msg_type: "error"}}
           ] ==
             TestHelper.exec_start_raw(%{
               exec_id: root_exec_id,
               attach: false,
               start_container: true
             })

    :timer.sleep(100)
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
