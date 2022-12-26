alias Jocker.Engine.{ZFS, Config, Container, Layer, Exec, Network, MetaData}
require Logger

Code.put_compiler_option(:warnings_as_errors, true)
ExUnit.start()

ExUnit.configure(
  seed: 0,
  trace: true,
  max_failures: 1
)

defmodule TestHelper do
  import ExUnit.Assertions

  use Plug.Test
  import Plug.Conn
  import OpenApiSpex.TestAssertions
  alias :gun, as: Gun
  alias Jocker.API.Router

  @opts Router.init([])

  def container_start_attached(api_spec, name, config) do
    %Container{id: container_id} = cont = container_create(api_spec, name, config)
    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: true, start_container: true})
    {cont, exec_id}
  end

  def container_create(api_spec, name, config) when not is_map_key(config, :image) do
    container_create(api_spec, name, Map.put(config, :image, "base"))
  end

  def container_create(api_spec, name, config) when not is_map_key(config, :jail_param) do
    container_create(api_spec, name, Map.put(config, :jail_param, ["mount.devfs=true"]))
  end

  def container_create(api_spec, name, config) when not is_map_key(config, :networks) do
    container_create(api_spec, name, Map.put(config, :networks, ["host"]))
  end

  def container_create(api_spec, name, config) do
    assert_schema(config, "ContainerConfig", api_spec)

    response =
      conn(:post, "/containers/create?name=#{name}", config)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    cond do
      response.status == 201 ->
        json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
        assert_schema(json_body, "IdResponse", api_spec)
        MetaData.get_container(json_body.id)

      response.status == 404 ->
        json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
        assert_schema(json_body, "ErrorResponse", api_spec)
        json_body

      true ->
        assert false
    end
  end

  def container_stop(api_spec, name) do
    response =
      conn(:post, "/containers/#{name}/stop")
      |> Router.call(@opts)

    status = response.status

    cond do
      status == 200 ->
        json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
        assert_schema(json_body, "IdResponse", api_spec)
        json_body

      status == 304 or status == 404 or status == 500 ->
        json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
        assert_schema(json_body, "ErrorResponse", api_spec)
        json_body

      true ->
        assert false
    end
  end

  def container_destroy(api_spec, name) do
    response =
      conn(:delete, "/containers/#{name}")
      |> Router.call(@opts)

    cond do
      response.status == 200 ->
        json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
        assert_schema(json_body, "IdResponse", api_spec)
        json_body

      response.status == 404 ->
        json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
        assert_schema(json_body, "ErrorResponse", api_spec)
        json_body

      true ->
        assert false
    end
  end

  def container_list(api_spec, all \\ true) do
    response =
      conn(:get, "/containers/list?all=#{all}")
      |> Router.call(@opts)

    assert response.status == 200
    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "ContainerSummaryList", api_spec)
    json_body
  end

  def collect_container_output(exec_id) do
    output = collect_container_output_(exec_id, [])
    output |> Enum.reverse() |> Enum.join("")
  end

  defp collect_container_output_(exec_id, output) do
    receive do
      {:container, ^exec_id, {:shutdown, :jail_stopped}} ->
        output

      {:container, ^exec_id, {:jail_output, msg}} ->
        collect_container_output_(exec_id, [msg | output])

      {:container, ^exec_id, msg} ->
        collect_container_output_(exec_id, [msg | output])
    end
  end

  def exec_create(api_spec, config) do
    assert_schema(config, "ExecConfig", api_spec)

    response =
      conn(:post, "/exec/create", config)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    cond do
      response.status == 201 ->
        json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
        assert_schema(json_body, "IdResponse", api_spec)
        {:ok, json_body.id}

      response.status == 404 ->
        json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
        assert_schema(json_body, "ErrorResponse", api_spec)
        json_body

      true ->
        assert false
    end
  end

  def exec_start(exec_id, %{attach: attach, start_container: start_container}) do
    initialize_websocket(
      "/exec/#{exec_id}/start?attach=#{attach}&start_container=#{start_container}"
    )
  end

  def exec_start_sync(exec_id, config) do
    {:ok, conn} = exec_start(exec_id, config)
    TestHelper.receive_frames(conn)
  end

  def exec_stop(api_spec, exec_id, %{
        force_stop: force_stop,
        stop_container: stop_container
      }) do
    endpoint = "/exec/#{exec_id}/stop?force_stop=#{force_stop}&stop_container=#{stop_container}"

    response =
      conn(:post, endpoint)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    cond do
      response.status == 200 ->
        json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
        assert_schema(json_body, "IdResponse", api_spec)
        {:ok, json_body.id}

      response.status == 404 ->
        json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
        assert_schema(json_body, "ErrorResponse", api_spec)
        json_body

      true ->
        assert false
    end
  end

  def image_build(config) do
    query_params = Plug.Conn.Query.encode(config)
    endpoint = "/images/build?#{query_params}"
    initialize_websocket(endpoint)
  end

  def initialize_websocket(endpoint) do
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
    end
  end

  defp receive_data(conn, stream_ref, buffer) do
    receive do
      {:gun_data, ^conn, {:websocket, ^stream_ref, _ws_data, [], %{}}, :fin, data} ->
        Logger.debug("received data: #{data}")
        data

      {:gun_data, ^conn, ^stream_ref, :nofin, data} ->
        Logger.debug("received data (more coming): #{data}")
        receive_data(conn, stream_ref, buffer <> data)

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

  def receive_frames(conn, frames \\ []) do
    case receive_frame(conn) do
      {:text, msg} ->
        receive_frames(conn, [msg | frames])

      {:close, 1001, ""} ->
        receive_frames(conn, [:not_attached])

      {:close, 1001, msg} ->
        receive_frames(conn, [msg | frames])

      {:close, 1000, msg} ->
        receive_frames(conn, [msg | frames])

      {:gun_down, ^conn, :ws, :closed, [], []} ->
        Enum.reverse(frames)

      :websocket_closed ->
        Enum.reverse(frames)
    end
  end

  def receive_frame(conn) do
    receive do
      {:gun_ws, ^conn, _ref, msg} ->
        Logger.info("message received from websocket: #{inspect(msg)}")
        msg

      {:gun_down, ^conn, :ws, :closed, [], []} ->
        :websocket_closed
    after
      1_000 -> {:error, :timeout}
    end
  end

  def create_network(config) when not is_map_key(config, :driver) do
    exit(:testhelper_error)
  end

  def create_network(config) do
    config_default = %{
      name: "testnet",
      subnet: "172.18.0.0/16",
      ifname: "vnet0"
    }

    config = Map.merge(config_default, config)

    {:ok, network_config} =
      OpenApiSpex.Cast.cast(
        Jocker.API.Schemas.NetworkConfig.schema(),
        config
      )

    Network.create(network_config)
  end

  def now() do
    :timer.sleep(10)
    DateTime.to_iso8601(DateTime.utc_now())
  end

  def clear_zroot() do
    {:ok, _pid} = Config.start_link([])
    zroot = Config.get("zroot")
    Agent.stop(Config)
    ZFS.destroy_force(zroot)
    ZFS.create(zroot)
  end

  def devfs_mounted(%Container{layer_id: layer_id}) do
    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)
    devfs_path = Path.join(mountpoint, "dev")

    case System.cmd("sh", ["-c", "mount | grep \"devfs on #{devfs_path}\""]) do
      {"", 1} -> false
      {_output, 0} -> true
    end
  end

  def build_and_return_image(context, dockerfile, tag) do
    quiet = false
    {:ok, pid} = Jocker.Engine.Image.build(context, dockerfile, tag, quiet)
    {_img, _messages} = result = receive_imagebuilder_results(pid, [])
    result
  end

  def receive_imagebuilder_results(pid, msg_list) do
    receive do
      {:image_builder, ^pid, {:image_finished, img}} ->
        {img, Enum.reverse(msg_list)}

      {:image_builder, ^pid, {:jail_output, msg}} ->
        receive_imagebuilder_results(pid, [msg | msg_list])

      {:image_builder, ^pid, msg} ->
        receive_imagebuilder_results(pid, [msg | msg_list])

      other ->
        Logger.warn("\nError! Received unkown message #{inspect(other)}")
    end
  end

  def create_tmp_dockerfile(content, dockerfile, context \\ "./") do
    :ok = File.write(Path.join(context, dockerfile), content, [:write])
  end
end
