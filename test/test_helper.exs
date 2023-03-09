alias Kleened.Core.{ZFS, Config, Layer, Exec, MetaData}
alias Kleened.API.Schemas
require Logger

Code.put_compiler_option(:warnings_as_errors, true)
ExUnit.start()

ExUnit.configure(
  seed: 0,
  trace: true,
  # timeout: 5_000,
  max_failures: 1
)

defmodule TestHelper do
  import ExUnit.Assertions

  use Plug.Test
  import Plug.Conn
  import OpenApiSpex.TestAssertions
  alias :gun, as: Gun
  alias Kleened.API.Router

  @opts Router.init([])

  def container_start_attached(api_spec, name, config) do
    %{id: container_id} = container_create(api_spec, name, config)
    cont = MetaData.get_container(container_id)
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
    config = Map.put(config, :networks, ["host"])

    container_create(api_spec, name, config)
  end

  def container_create(api_spec, name, config) do
    config =
      case is_list(config.networks) do
        true ->
          networks_map =
            Map.new(Enum.map(config.networks, &{&1, %Schemas.EndPointConfig{container: "dummy"}}))

          %{config | networks: networks_map}

        false ->
          config
      end

    assert_schema(config, "ContainerConfig", api_spec)

    response =
      conn(:post, "/containers/create?name=#{name}", config)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      201 => "IdResponse",
      404 => "ErrorResponse"
    })
  end

  def container_stop(api_spec, name) do
    response =
      conn(:post, "/containers/#{name}/stop")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      200 => "IdResponse",
      304 => "ErrorResponse",
      404 => "ErrorResponse"
    })
  end

  def container_remove(api_spec, name) do
    response =
      conn(:delete, "/containers/#{name}")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      200 => "IdResponse",
      404 => "ErrorResponse"
    })
  end

  def container_list(api_spec, all \\ true) do
    response =
      conn(:get, "/containers/list?all=#{all}")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      200 => "ContainerSummaryList"
    })
  end

  def collect_container_output(exec_id) do
    output = collect_container_output_(exec_id, [])
    output |> Enum.reverse() |> Enum.join("")
  end

  defp collect_container_output_(exec_id, output) do
    receive do
      {:container, ^exec_id, {:shutdown, {:jail_stopped, _exit_code}}} ->
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

    validate_response(api_spec, response, %{
      201 => "IdResponse",
      404 => "ErrorResponse"
    })
  end

  def exec_start(exec_id, %{attach: attach, start_container: start_container}) do
    initialize_websocket(
      "/exec/#{exec_id}/start?attach=#{attach}&start_container=#{start_container}"
    )
  end

  def exec_start_sync(exec_id, config) do
    {:ok, _stream_ref, conn} = exec_start(exec_id, config)
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

    validate_response(api_spec, response, %{
      200 => "IdResponse",
      404 => "ErrorResponse"
    })
  end

  def image_invalid_build(config) do
    config = Map.merge(%{quiet: false}, config)
    frames = image_build(config)
    {finish_msg, _build_log} = List.pop_at(frames, -1)
    assert <<"image build failed: ", failed_line::binary>> = finish_msg
    failed_line
  end

  def image_valid_build(config) do
    config = Map.merge(%{quiet: false}, config)
    frames = image_build(config)
    {finish_msg, build_log} = List.pop_at(frames, -1)
    assert <<"image created with id ", image_id::binary>> = finish_msg
    image = MetaData.get_image(String.trim(image_id))
    {image, build_log}
  end

  def image_build(config) do
    config =
      case Map.has_key?(config, :buildargs) do
        true ->
          {:ok, buildargs_json} = Jason.encode(config.buildargs)
          Map.put(config, :buildargs, buildargs_json)

        false ->
          config
      end

    image_build_raw(config)
  end

  def image_build_raw(config) do
    query_params = Plug.Conn.Query.encode(config)
    endpoint = "/images/build?#{query_params}"

    case initialize_websocket(endpoint) do
      {:ok, _stream_ref, conn} ->
        receive_frames(conn)

      error_msg ->
        error_msg
    end
  end

  def image_list(api_spec) do
    response =
      conn(:get, "/images/list")
      |> Router.call(@opts)

    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "ImageList", api_spec)
    json_body
  end

  def image_destroy(api_spec, image_id) do
    response =
      conn(:delete, "/images/#{image_id}")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      200 => "IdResponse",
      404 => "ErrorResponse"
    })
  end

  def network_create(_api_spec, config) when not is_map_key(config, :driver) do
    exit(:testhelper_error)
  end

  def network_create(api_spec, config) do
    config_default = %{
      name: "testnet",
      subnet: "172.18.0.0/16",
      ifname: "vnet0"
    }

    config = Map.merge(config_default, config)
    assert_schema(config, "NetworkConfig", api_spec)

    response =
      conn(:post, "/networks/create", config)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      201 => "IdResponse",
      409 => "ErrorResponse"
    })
  end

  def network_destroy(api_spec, name) do
    response =
      conn(:delete, "/networks/#{name}")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      200 => "IdResponse",
      404 => "ErrorResponse"
    })
  end

  def network_list(api_spec) do
    response =
      conn(:get, "/networks/list")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      200 => "NetworkList"
    })
  end

  def network_connect(api_spec, network_id, container_id) when is_binary(container_id) do
    connect_config = %{container: container_id}
    network_connect(api_spec, network_id, connect_config)
  end

  def network_connect(api_spec, network_id, config) do
    response =
      conn(:post, "/networks/#{network_id}/connect", config)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      204 => "",
      404 => "ErrorResponse",
      409 => "ErrorResponse"
    })
  end

  def network_disconnect(api_spec, container_id, network_id) do
    response =
      conn(:post, "/networks/#{network_id}/disconnect/#{container_id}")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      204 => "",
      409 => "ErrorResponse"
    })
  end

  defp validate_response(api_spec, response, statuscodes_to_specs) do
    %{status: status, resp_body: resp_body} = response

    response_spec = Map.get(statuscodes_to_specs, status)

    cond do
      response_spec == nil ->
        assert false

      response_spec == "" ->
        :ok

      true ->
        json_body = Jason.decode!(resp_body, [{:keys, :atoms}])
        assert_schema(json_body, response_spec, api_spec)
        json_body
    end
  end

  def initialize_websocket(endpoint) do
    {:ok, conn} = Gun.open(:binary.bin_to_list("localhost"), 8085)
    {:ok, :http} = Gun.await_up(conn)

    :gun.ws_upgrade(conn, :binary.bin_to_list(endpoint))

    receive do
      {:gun_upgrade, ^conn, stream_ref, ["websocket"], _headers} ->
        Logger.info("websocket initialized")
        {:ok, stream_ref, conn}

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

  def send_data(conn, stream_ref, data) do
    Gun.ws_send(conn, stream_ref, {:text, data})
  end

  defp receive_data(conn, stream_ref, buffer) do
    receive do
      {:gun_data, ^conn, ^stream_ref, :fin, data} ->
        Logger.debug("received data: #{data}")
        data

      {:gun_data, ^conn, ^stream_ref, :nofin, data} ->
        Logger.debug("received data (more coming): #{data}")
        receive_data(conn, stream_ref, buffer <> data)
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

      :websocket_closed ->
        Enum.reverse(frames)
    end
  end

  def receive_frame(conn) do
    receive do
      {:gun_ws, ^conn, _ref, msg} ->
        Logger.info("message received from websocket: #{inspect(msg)}")
        msg

      {:gun_down, ^conn, :ws, {:error, :closed}, [_stream_ref]} ->
        :websocket_closed

      {:gun_down, ^conn, :ws, :normal, [_stream_ref]} ->
        :websocket_closed
    after
      1_000 -> {:error, :timeout}
    end
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

  def devfs_mounted(%Schemas.Container{layer_id: layer_id}) do
    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    devfs_path = Path.join(mountpoint, "dev")

    case System.cmd("sh", ["-c", "mount | grep \"devfs on #{devfs_path}\""]) do
      {"", 1} -> false
      {_output, 0} -> true
    end
  end

  def create_tmp_dockerfile(content, dockerfile, context \\ "./") do
    :ok = File.write(Path.join(context, dockerfile), content, [:write])
  end
end
