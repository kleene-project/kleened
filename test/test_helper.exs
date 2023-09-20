alias OpenApiSpex.Cast
alias Kleened.Core.{Const, ZFS, Config, Layer, Exec, MetaData, Container}
alias :gun, as: Gun
alias Kleened.API.Router
alias Kleened.API.Schemas
alias Schemas.WebSocketMessage, as: Msg

require Logger

Code.put_compiler_option(:warnings_as_errors, true)
ExUnit.start()

ExUnit.configure(
  seed: 0,
  trace: true,
  # timeout: 5_000,
  max_failures: 1
)

TestInitialization.create_test_base_image()

defmodule TestHelper do
  import ExUnit.Assertions
  use Plug.Test
  import Plug.Conn
  import OpenApiSpex.TestAssertions

  @kleened_host {0, 0, 0, 0, 0, 0, 0, 1}
  @opts Router.init([])

  def container_run(api_spec, config) do
    config_create = %{
      image: config.image,
      cmd: config.cmd
    }

    %{id: container_id} = TestHelper.container_create(api_spec, "testrun", config_create)
    {:ok, exec_id} = Exec.create(container_id)

    {closing_msg, process_output} =
      valid_execution(%{exec_id: exec_id, attach: config.attach, start_container: true})

    {:ok, ^container_id} = Container.remove(container_id)
    {closing_msg, process_output}
  end

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
    {networks, config} = Map.pop(config, :networks)
    assert_schema(config, "ContainerConfig", api_spec)

    response =
      conn(:post, "/containers/create?name=#{name}", config)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    case validate_response(api_spec, response, %{
           201 => "IdResponse",
           404 => "ErrorResponse"
         }) do
      %{id: container_id} = resp ->
        Enum.map(networks, &network_connect(api_spec, &1, container_id))
        resp

      resp ->
        resp
    end
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

  def exec_start(exec_id, config) do
    config = Map.put(config, :exec_id, exec_id)
    {:ok, stream_ref, conn} = initialize_websocket("/exec/start")
    send_data(conn, stream_ref, Jason.encode!(config))

    case config.attach do
      true ->
        {:text, starting_frame} = receive_frame(conn, 1_000)

        assert {:ok, %{msg_type: "starting"}} =
                 Cast.cast(
                   Msg.schema(),
                   Jason.decode!(starting_frame, keys: :atoms!)
                 )

      false ->
        :ok
    end

    {:ok, stream_ref, conn}
  end

  def valid_execution(%{attach: true} = config) do
    [msg_json | rest] = exec_start_raw(config)

    assert {:ok, %Msg{data: "", message: "", msg_type: "starting"}} ==
             Cast.cast(Msg.schema(), Jason.decode!(msg_json, keys: :atoms!))

    {{1000, %Msg{msg_type: "closing", message: closing_msg}}, process_output} =
      List.pop_at(rest, -1)

    {closing_msg, process_output}
  end

  def valid_execution(%{attach: false} = config) do
    [{1001, %Msg{msg_type: "closing", message: closing_msg}}] = exec_start_raw(config)
    closing_msg
  end

  def exec_start_raw(config) do
    case initialize_websocket("/exec/start") do
      {:ok, stream_ref, conn} ->
        send_data(conn, stream_ref, Jason.encode!(config))
        receive_frames(conn)

      error_msg ->
        error_msg
    end
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

  def test_image() do
    TestInitialization.test_image()
  end

  def image_invalid_build(config) do
    config = Map.merge(%{quiet: false, cleanup: true}, config)
    build_log_raw = image_build_raw(config)
    process_failed_buildlog(build_log_raw)
  end

  def image_valid_build(config) do
    config = Map.merge(%{quiet: false, cleanup: true}, config)
    build_log_raw = image_build_raw(config)
    process_buildlog(build_log_raw, config)
  end

  def process_failed_buildlog([msg_json | rest]) do
    {:ok, %Msg{data: image_id}} = Cast.cast(Msg.schema(), Jason.decode!(msg_json, keys: :atoms!))

    {error_type, build_log} =
      case List.pop_at(rest, -1) do
        {{1011, %Msg{msg_type: "error", message: "image build failed", data: ""}}, build_log} ->
          {:failed_build, build_log}

        {{1011, %Msg{msg_type: "error", message: "image build failed", data: id}}, build_log} ->
          # image id of the failed image
          {:failed_build, {build_log, id}}

        {{1011, %Msg{msg_type: "error", message: "failed to process Dockerfile"}}, build_log} ->
          {:invalid_dockerfile, build_log}
      end

    {error_type, image_id, build_log}
  end

  def process_buildlog([msg_json | rest], config) do
    {:ok, %Msg{data: image_id}} = Cast.cast(Msg.schema(), Jason.decode!(msg_json, keys: :atoms!))
    {{1000, %Msg{data: ^image_id}}, build_log} = List.pop_at(rest, -1)
    image = MetaData.get_image(image_id)
    process_output = process_buildlog_(config, image.instructions, build_log)
    {image, process_output}
  end

  defp process_buildlog_(config, instructsnaps, build_log) do
    nsteps = length(instructsnaps)
    step = 0

    snapshots =
      Enum.map(instructsnaps, fn [_, snap] -> snap end)
      |> Enum.filter(fn snap -> snap != "" end)

    instructions = Enum.map(instructsnaps, fn [instruction, _] -> instruction end)

    process_buildlog_(config, step, nsteps, instructions, snapshots, build_log, [])
  end

  defp process_buildlog_(
         config,
         step,
         nsteps,
         instructions,
         snapshots,
         [log_entry | build_log],
         process_output
       ) do
    instruction_result =
      case instructions do
        [instruction | remaining_instructions] ->
          step = step + 1
          status_msg = Const.image_builder_status_message(step, nsteps, instruction)

          if status_msg == log_entry do
            process_buildlog_(
              config,
              step,
              nsteps,
              remaining_instructions,
              snapshots,
              build_log,
              process_output
            )
          else
            :no_result
          end

        [] ->
          :no_result
      end

    snapshot_result =
      case snapshots do
        [snapshot | remaining_snapshots] ->
          snapshot_msg = Const.image_builder_snapshot_message(snapshot)

          if snapshot_msg == log_entry do
            process_buildlog_(
              config,
              step,
              nsteps,
              instructions,
              remaining_snapshots,
              build_log,
              process_output
            )
          else
            :no_result
          end

        [] ->
          :no_result
      end

    cond do
      instruction_result != :no_result ->
        instruction_result

      snapshot_result != :no_result ->
        snapshot_result

      true ->
        # If neither snapshot nor instruction produced a match the log entry must be process output.
        process_buildlog_(
          config,
          step,
          nsteps,
          instructions,
          snapshots,
          build_log,
          [log_entry | process_output]
        )
    end
  end

  defp process_buildlog_(
         config,
         step,
         nsteps,
         instructions,
         snapshots,
         [],
         process_output
       ) do
    case config do
      %{quiet: false} ->
        assert step == nsteps
        assert instructions == []
        assert snapshots == []

      %{quiet: true} ->
        :ok
    end

    Enum.reverse(process_output)
  end

  def image_build_raw(config) do
    case initialize_websocket("/images/build") do
      {:ok, stream_ref, conn} ->
        send_data(conn, stream_ref, Jason.encode!(config))
        receive_frames(conn)

      error_msg ->
        error_msg
    end
  end

  def image_create(config) do
    case initialize_websocket("/images/create") do
      {:ok, stream_ref, conn} ->
        send_data(conn, stream_ref, Jason.encode!(config))
        receive_frames(conn, 20_000)

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
    network_connect(api_spec, network_id, %{container: container_id})
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
    {:ok, conn} = Gun.open(@kleened_host, 8080, %{protocols: [:http]})

    {:ok, :http} = Gun.await_up(conn)

    :gun.ws_upgrade(conn, :binary.bin_to_list(endpoint))

    receive do
      {:gun_upgrade, ^conn, stream_ref, ["websocket"], _headers} ->
        Logger.info("websocket initialized")
        {:ok, stream_ref, conn}

      {:gun_response, ^conn, stream_ref, :nofin, status, _headers} ->
        Logger.error("failed for a unknown reason with status #{status}. Fetching repsonse data.")
        response = receive_data(conn, stream_ref, "")
        {:error, response}

      {:gun_response, ^conn, _stream_ref, :fin, status, headers} = msg ->
        Logger.error("failed for a unknown reason with no data: #{inspect(msg)}")
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

  def receive_frames(conn, timeout \\ 5_000) do
    receive_frames_(conn, [], timeout)
  end

  defp receive_frames_(conn, frames, timeout) do
    case receive_frame(conn, timeout) do
      {:text, msg} ->
        receive_frames_(conn, [msg | frames], timeout)

      {:close, close_code, msg} ->
        {:ok, msg} = Cast.cast(Msg.schema(), Jason.decode!(msg))
        receive_frames_(conn, [{close_code, msg} | frames], timeout)

      {:error, reason} ->
        Logger.warn("receiving frames failed: #{reason}")
        :error

      :websocket_closed ->
        Enum.reverse(frames)
    end
  end

  def receive_frame(conn, timeout \\ 5_000) do
    receive do
      {:gun_ws, ^conn, _ref, msg} ->
        Logger.debug("message received from websocket: #{inspect(msg)}")
        msg

      {:gun_down, ^conn, :ws, {:error, :closed}, [_stream_ref]} ->
        :websocket_closed

      {:gun_down, ^conn, :ws, :normal, [_stream_ref]} ->
        :websocket_closed

      {:gun_down, ^conn, :ws, :closed, [_stream_ref]} ->
        {:error, "websocket closed unexpectedly"}
    after
      timeout -> {:error, "timed out while waiting for websocket frames"}
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
    :timer.sleep(500)
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
