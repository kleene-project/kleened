defmodule WebSocketTest do
  use ExUnit.Case
  require Logger

  alias Jocker.Engine.{Container, Image}
  alias :gun, as: Gun

  @moduletag :capture_log

  test "try attaching to a non-existing container" do
    conn = initialize_websocket("/containers/nonexisting/attach")
    ["container not found"] = receive_frames(conn)
    # The underlying ranch-listener complains if this delay is not here:
    :timer.sleep(1000)
  end

  test "attach to actual container and receive some output from it" do
    create_opt = [image: "base", cmd: ["/bin/sh", "-c", "uname"]]
    {:ok, container} = Container.create(create_opt)
    conn = initialize_websocket("/containers/#{container.id}/attach")
    assert {:text, "ok:"} == receive_frame(conn)
    {:ok, _} = Container.start(container.id)
    expected_frames = ["FreeBSD\n", "container #{container.id} stopped"]
    assert expected_frames == receive_frames(conn)
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
        tag: "<none>:<none>"
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
  end

  defp receive_frames(conn, frames \\ []) do
    case receive_frame(conn) do
      {:text, <<"exit:", msg::binary>>} ->
        Enum.reverse([msg | frames])

      {:text, <<"io:", msg::binary>>} ->
        receive_frames(conn, [msg | frames])

      {:close, 1000, <<"exit:", msg::binary>>} ->
        receive_frames(conn, [msg | frames])

      :websocket_closed ->
        Enum.reverse(frames)
    end
  end

  defp receive_frame(conn) do
    receive do
      {:gun_ws, ^conn, _ref, msg} ->
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
      _ -> Logger.info("connection up!")
    end

    :gun.ws_upgrade(conn, :binary.bin_to_list(endpoint))

    receive do
      {:gun_upgrade, ^conn, stream_ref, ["websocket"], _headers} ->
        Logger.info("websocket initialized")
        stream_ref

      {:gun_response, ^conn, _, _, status, headers} ->
        exit({:ws_upgrade_failed, status, headers})

      {:gun_error, ^conn, _stream_ref, reason} ->
        exit({:ws_upgrade_failed, reason})

      msg ->
        exit({:ws_upgrade_failed, "unknown message '#{inspect(msg)}' received."})
    end

    conn
  end
end
