defmodule WebSocketTest do
  use ExUnit.Case
  require Logger

  alias Jocker.Engine.{Exec, Container, Image}
  alias :gun, as: Gun

  @moduletag :capture_log

  test "try starting and attaching to a non-existing execution instance" do
    {:ok, conn} = initialize_websocket("/exec/nonexisting/start?attach=true&start_container=true")
    ["could not find a execution instance matching 'nonexisting'"] = receive_frames(conn)
  end

  test "try executing a non-existining execution instance with invalid parameters" do
    {:error, "invalid value/missing parameter(s)"} =
      initialize_websocket("/exec/nonexisting/start?attach=mustbeboolean&start_container=true")

    {:error, "invalid value/missing parameter(s)"} =
      initialize_websocket("/exec/nonexisting/start?nonexisting_param=true&start_container=true")
  end

  test "try starting the first execution instance start_container=false" do
    {:ok, container} =
      TestHelper.create_container("ws_test_container", %{
        image: "base",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    {:ok, exec_id} = Exec.create(container.id)
    container_id = container.id
    {:ok, conn} = initialize_websocket("/exec/#{exec_id}/start?attach=true&start_container=false")
    assert ["cannot start container when 'start_container' is false."] == receive_frames(conn)
    {:ok, ^container_id} = Container.destroy(container_id)
  end

  test "attach to actual container and receive some output from it" do
    {:ok, container} =
      TestHelper.create_container("ws_test_container", %{
        image: "base",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    {:ok, exec_id} = Exec.create(container.id)
    stop_msg = "executable #{exec_id} stopped"
    container_id = container.id
    {:ok, conn} = initialize_websocket("/exec/#{exec_id}/start?attach=true&start_container=true")
    assert ["OK", "FreeBSD\n", stop_msg] == receive_frames(conn)
    {:ok, ^container_id} = Container.destroy(container_id)
  end

  test "start container quickly several times to verify reproducibility" do
    {:ok, container} =
      TestHelper.create_container("ws_test_container", %{
        image: "base",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    container_id = container.id
    :ok = start_attached_container_and_receive_output(container.id, 20)
    {:ok, ^container_id} = Container.destroy(container_id)
  end

  test "start container without attaching to it" do
    {:ok, container} =
      TestHelper.create_container("ws_test_container", %{
        image: "base",
        cmd: ["/bin/sh", "-c", "uname"]
      })

    {:ok, exec_id} = Exec.create(container.id)
    stop_msg = "executable #{exec_id} stopped"

    container_id = container.id
    {:ok, conn} = initialize_websocket("/exec/#{exec_id}/start?attach=false&start_container=true")
    assert [:not_attached] == receive_frames(conn)
    {:ok, ^container_id} = Container.destroy(container_id)
  end

  @tmp_dockerfile "tmp_dockerfile"
  @tmp_context "./"

  test "building a simple image that generates some text" do
    dockerfile = """
    FROM scratch
    RUN echo "lets test that we receives this!"
    RUN uname
    """

    TestHelper.create_tmp_dockerfile(dockerfile, @tmp_dockerfile)

    query_params =
      Plug.Conn.Query.encode(%{
        context: @tmp_context,
        dockerfile: @tmp_dockerfile,
        quiet: false,
        tag: "websock_img:latest"
      })

    endpoint = "/images/build?#{query_params}"
    conn = initialize_websocket(endpoint)
    assert {:text, "ok:"} == receive_frame(conn)
    frames = receive_frames(conn)

    {finish_msg, build_log} = List.pop_at(frames, -1)

    assert build_log == [
             "Step 1/3 : FROM scratch\n",
             "Step 2/3 : RUN echo \"lets test that we receives this!\"\n",
             "lets test that we receives this!\n",
             "Step 3/3 : RUN uname\n",
             "FreeBSD\n"
           ]

    assert <<"image created with id ", _::binary>> = finish_msg
    Image.destroy("websock_img")
  end

  defp start_attached_container_and_receive_output(_container_id, 0) do
    :ok
  end

  defp start_attached_container_and_receive_output(container_id, number_of_starts) do
    {:ok, exec_id} = Exec.create(container_id)
    stop_msg = "executable #{exec_id} stopped"
    {:ok, conn} = initialize_websocket("/exec/#{exec_id}/start?attach=true&start_container=true")
    assert ["OK", "FreeBSD\n", stop_msg] == receive_frames(conn)
    start_attached_container_and_receive_output(container_id, number_of_starts - 1)
  end

  defp receive_frames(conn, frames \\ []) do
    case receive_frame(conn) do
      {:text, msg} ->
        receive_frames(conn, [msg | frames])

      {:close, 1001, ""} ->
        receive_frames(conn, [:not_attached])

      {:close, 1000, msg} ->
        receive_frames(conn, [msg | frames])

      {:gun_down, ^conn, :ws, :closed, [], []} ->
        Enum.reverse(frames)

      :websocket_closed ->
        Enum.reverse(frames)

      unknown_message ->
        IO.puts("Unknown message received: ", unknown_message)
    end
  end

  defp receive_frame(conn) do
    receive do
      {:gun_ws, ^conn, _ref, msg} ->
        Logger.info("message received from websocket: #{inspect(msg)}")
        msg

      {:gun_down, ^conn, :ws, :closed, [], []} ->
        :websocket_closed

      what ->
        Logger.error("unknown message received #{inspect(what)}")
        {:error, :unknown_msg}
    after
      1_000 -> {:error, :timeout}
    end
  end

  defp initialize_websocket(endpoint) do
    {:ok, conn} = Gun.open(:binary.bin_to_list("localhost"), 8085)

    receive do
      {:gun_up, ^conn, :http} -> :ok
      msg -> Logger.info("connection up! #{inspect(msg)}")
    end

    :gun.ws_upgrade(conn, :binary.bin_to_list(endpoint))

    receive do
      {:gun_upgrade, ^conn, _stream_ref, ["websocket"], _headers} ->
        Logger.info("websocket initialized")
        {:ok, conn}

      {:gun_response, ^conn, stream_ref, :nofin, 400, _headers} ->
        Logger.info("Failed with status 400 (invalid parameters). Fetching repsonse data.")
        response = receive_data(conn, stream_ref, "")
        {:error, response}

      {:gun_response, ^conn, stream_ref, :nofin, status, _headers} ->
        Logger.error("failed for a unknown reason with status #{status}. Fetching repsonse data.")
        response = receive_data(conn, stream_ref, "")
        {:error, response}

      {:gun_response, ^conn, _stream_ref, :fin, status, headers} = msg ->
        Logger.error("failed for a unknown reason with no data: #{msg}")
        exit({:ws_upgrade_failed, status, headers})

      {:gun_error, ^conn, _stream_ref, reason} ->
        exit({:ws_upgrade_failed, reason})

      msg ->
        exit({:ws_upgrade_failed, "unknown message '#{inspect(msg)}' received."})
    end
  end

  defp receive_data(conn, stream_ref, buffer) do
    receive do
      {:gun_data, ^conn, {:websocket, ^stream_ref, _ws_data, [], %{}}, :fin, data} ->
        Logger.info("received data: #{data}")
        data

      {:gun_data, ^conn, ^stream_ref, :nofin, data} ->
        Logger.info("received data (more coming): #{data}")
        receive_data(conn, stream_ref, buffer <> data)

      # {:gun_data, ^conn, ^stream_ref, :fin, data} ->
      #  data

      unknown ->
        Logger.warn(
          "Unknown data received while waiting for websocket initialization data: #{
            inspect(unknown)
          }"
        )
    after
      1000 ->
        exit("timed out while waiting for response data during websocket initialization.")
    end
  end
end
