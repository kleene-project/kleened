alias OpenApiSpex.Cast
alias Kleened.Test.TestImage
alias Kleened.Core.{Const, Exec, Image, Container, Volume, Network, MetaData, ZFS, OS}
alias :gun, as: Gun
alias Kleened.API.Router
alias Kleened.API.Schemas
alias Schemas.WebSocketMessage, as: Msg

require Logger

# Code.put_compiler_option(:warnings_as_errors, true)
ExUnit.start()

ExUnit.configure(
  seed: 0,
  trace: true,
  # timeout: 5_000,
  max_failures: 1
)

TestImage.create_test_base_image()

defmodule TestHelper do
  import ExUnit.Assertions
  use Plug.Test
  import Plug.Conn
  import OpenApiSpex.TestAssertions

  @kleened_host {0, 0, 0, 0, 0, 0, 0, 1}
  @opts Router.init([])

  def cleanup() do
    Logger.info("Cleaning up after test...")
    runnning_containers = Container.list(all: false)

    case length(runnning_containers) do
      0 ->
        :ok

      _ ->
        runnning_containers |> Enum.map(fn %{id: id} -> Container.stop(id) end)

        :timer.sleep(500)
    end

    MetaData.list_containers() |> Enum.map(fn %{id: id} -> Container.remove(id) end)

    MetaData.list_volumes() |> Enum.map(&Volume.remove(&1.name))

    MetaData.list_networks()
    |> Enum.map(fn %{id: id} -> Network.remove(id) end)

    # Image.prune(true)
    MetaData.list_images()
    |> Enum.filter(fn %Schemas.Image{name: name, tag: tag} ->
      name != "FreeBSD" or tag != "testing"
    end)
    |> Enum.map(fn %Schemas.Image{id: id} -> Image.remove(id) end)
  end

  def setup() do
    TestImage.create_test_base_image()
  end

  def container_valid_run(config) do
    {container_id, exec_config, expected_exit} = prepare_container_run(config)

    {closing_msg, output} = exec_valid_start(exec_config)

    {attach, _} = Map.pop(config, :attach, true)

    if attach and is_integer(expected_exit) do
      assert String.slice(closing_msg, -11, 11) == "exit-code #{expected_exit}"
    end

    {container_id, closing_msg, output}
  end

  def container_valid_run_async(config) do
    # Ignoring expected_exit since the caller will deal with this
    {container_id, exec_config, _expected_exit} = prepare_container_run(config)
    {:ok, conn} = exec_start_raw(exec_config)
    {container_id, exec_config.exec_id, conn}
  end

  defp prepare_container_run(config) do
    {attach, config} = Map.pop(config, :attach, true)
    {start_container, config} = Map.pop(config, :start_container, true)
    {expected_exit, config} = Map.pop(config, :expected_exit_code, 0)

    %{id: container_id} = TestHelper.container_create(config)
    {:ok, exec_id} = Exec.create(container_id)

    exec_config = %{exec_id: exec_id, attach: attach, start_container: start_container}

    {container_id, exec_config, expected_exit}
  end

  def container_start(container_id, config \\ %{}) do
    attach = Map.get(config, :attach, true)
    start_container = Map.get(config, :start_container, true)
    {:ok, exec_id} = Exec.create(container_id)

    {closing_msg, process_output} =
      exec_valid_start(%{exec_id: exec_id, attach: attach, start_container: start_container})

    {closing_msg, process_output}
  end

  def container_start_attached(_api_spec, container_id) when is_binary(container_id) do
    cont = MetaData.get_container(container_id)
    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: true, start_container: true})
    {cont, exec_id}
  end

  def container_start_attached(_api_spec, config) do
    %{id: container_id} = container_create(config)
    cont = MetaData.get_container(container_id)
    {:ok, exec_id} = Exec.create(container_id)
    :ok = Exec.start(exec_id, %{attach: true, start_container: true})
    {cont, exec_id}
  end

  def container_create(config) do
    api_spec = Kleened.API.Spec.spec()

    config_default = %{
      image: "FreeBSD:testing",
      jail_param: ["mount.devfs=true"],
      network_driver: "host",
      public_ports: []
    }

    config = Map.merge(config_default, config)

    {network_name, config} = Map.pop(config, :network, "")
    {ip_address, config} = Map.pop(config, :ip_address, "<auto>")
    {ip_address6, config} = Map.pop(config, :ip_address6, "")
    assert_schema(config, "ContainerConfig", api_spec)

    response =
      conn(:post, "/containers/create?name=#{config.name}", config)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    case validate_response(api_spec, response, %{
           201 => "IdResponse",
           404 => "ErrorResponse"
         }) do
      %{id: container_id} = resp ->
        case network_name do
          "" ->
            resp

          _ ->
            endpoint_config = %{
              container: container_id,
              ip_address: ip_address,
              ip_address6: ip_address6
            }

            case network_connect(api_spec, network_name, endpoint_config) do
              :ok -> resp
              other -> other
            end
        end

      resp ->
        resp
    end
  end

  def container_prune(api_spec) do
    response =
      conn(:post, "/containers/prune")
      |> Router.call(@opts)

    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "IdListResponse", api_spec)
    json_body
  end

  def container_update(api_spec, container_ident, config) do
    assert_schema(config, "ContainerConfig", api_spec)

    response =
      conn(:post, "/containers/#{container_ident}/update", config)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      201 => "IdResponse",
      409 => "ErrorResponse",
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
      404 => "ErrorResponse",
      409 => "ErrorResponse"
    })
  end

  def container_inspect_raw(container_ident) do
    conn(:get, "/containers/#{container_ident}/inspect")
    |> Router.call(@opts)
  end

  def container_inspect(container_ident) do
    response = container_inspect_raw(container_ident)

    %{container: container, container_endpoints: endpoints, container_mountpoints: mountpoints} =
      Jason.decode!(response.resp_body, [{:keys, :atoms}])

    %{
      container: struct(Schemas.Container, container),
      container_endpoints: Enum.map(endpoints, &struct(Schemas.EndPoint, &1)),
      container_mountpoints: Enum.map(mountpoints, &struct(Schemas.MountPoint, &1))
    }
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
    timeout = 10_000

    receive do
      {:container, ^exec_id, {:shutdown, {:jail_stopped, _exit_code}}} ->
        output

      {:container, ^exec_id, {:jail_output, msg}} ->
        collect_container_output_(exec_id, [msg | output])

      {:container, ^exec_id, msg} ->
        collect_container_output_(exec_id, [msg | output])
    after
      timeout -> {:error, "timed out while waiting for container messages"}
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

  def exec_valid_start(%{attach: true} = config) do
    {:ok, conn} = exec_start_raw(config)
    [msg_json | rest] = receive_frames(conn, 120_000)

    assert {:ok, %Msg{data: "", message: "", msg_type: "starting"}} ==
             Cast.cast(Msg.schema(), Jason.decode!(msg_json, keys: :atoms!))

    {{1000, %Msg{msg_type: "closing", message: closing_msg}}, process_output} =
      List.pop_at(rest, -1)

    {closing_msg, process_output}
  end

  def exec_valid_start(%{attach: false} = config) do
    {:ok, conn} = exec_start_raw(config)
    [{1001, %Msg{msg_type: "closing", message: closing_msg}}] = receive_frames(conn)
    {closing_msg, ""}
  end

  def exec_start(config) do
    {:ok, conn} = exec_start_raw(config)
    receive_frames(conn, 5_000)
  end

  def exec_start_raw(config) do
    case initialize_websocket("/exec/start") do
      {:ok, stream_ref, conn} ->
        send_data(conn, stream_ref, Jason.encode!(config))
        {:ok, conn}

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

  def image_prune(api_spec, all) do
    endpoint =
      case all do
        true -> "/images/prune?all=true"
        false -> "/images/prune?all=false"
      end

    response =
      conn(:post, endpoint)
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      200 => "IdListResponse"
    })
  end

  def image_tag(api_spec, image_ident, nametag) do
    endpoint = "/images/#{image_ident}/tag?nametag=#{nametag}"

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

  def base_image_create(%{method: method} = config) do
    case method do
      "zfs-copy" ->
        dataset = config.zfs_dataset
        ZFS.create(dataset)

        {_, 0} =
          OS.cmd(["/usr/bin/tar", "-xf", "./test/data/minimal_testjail.txz", "-C", "/#{dataset}"])

      _ ->
        :ok
    end

    frames = TestHelper.image_create(config)
    {{1000, closing_msg}, _rest} = List.pop_at(frames, -1)
    assert %Msg{data: _, message: "image created", msg_type: "closing"} = closing_msg
    closing_msg.data
  end

  def image_list(api_spec) do
    response =
      conn(:get, "/images/list")
      |> Router.call(@opts)

    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "ImageList", api_spec)
    json_body
  end

  def image_inspect_raw(image_ident) do
    conn(:get, "/images/#{image_ident}/inspect")
    |> Router.call(@opts)
  end

  def image_remove(api_spec, image_id) do
    response =
      conn(:delete, "/images/#{image_id}")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      200 => "IdResponse",
      404 => "ErrorResponse"
    })
  end

  def network_create(config) do
    api_spec = Kleened.API.Spec.spec()
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

  def network_remove(api_spec, name) do
    response =
      conn(:delete, "/networks/#{name}")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      200 => "IdResponse",
      404 => "ErrorResponse"
    })
  end

  def network_prune(api_spec) do
    response =
      conn(:post, "/networks/prune")
      |> Router.call(@opts)

    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "IdListResponse", api_spec)
    json_body
  end

  def network_inspect(network_ident) do
    response = network_inspect_raw(network_ident)
    Jason.decode!(response.resp_body, [{:keys, :atoms}])
  end

  def network_inspect_raw(network_ident) do
    conn(:get, "/networks/#{network_ident}/inspect")
    |> Router.call(@opts)
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
    network_connect(api_spec, network_id, %{
      container: container_id,
      ip_address: "<auto>"
    })
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

  def network_disconnect(api_spec, network_id, container_id) do
    response =
      conn(:post, "/networks/#{network_id}/disconnect/#{container_id}")
      |> Router.call(@opts)

    validate_response(api_spec, response, %{
      204 => "",
      409 => "ErrorResponse"
    })
  end

  def volume_remove(api_spec, name) do
    response =
      conn(:delete, "/volumes/#{name}")
      |> Router.call(@opts)

    assert response.status == 200
    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "IdResponse", api_spec)
  end

  def volume_prune(api_spec) do
    response =
      conn(:post, "/volumes/prune")
      |> Router.call(@opts)

    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "IdListResponse", api_spec)
    json_body
  end

  def volume_inspect(name) do
    conn(:get, "/volumes/#{name}/inspect")
    |> Router.call(@opts)
  end

  def volume_create(api_spec, name) do
    response =
      conn(:post, "/volumes/create", %{name: name})
      |> put_req_header("content-type", "application/json")
      |> Router.call(@opts)

    assert response.status == 201
    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "IdResponse", api_spec)
    MetaData.get_volume(json_body.id) |> Map.drop([:__struct__])
  end

  def volume_list(api_spec) do
    response = conn(:get, "/volumes/list") |> Router.call(@opts)
    assert response.status == 200
    json_body = Jason.decode!(response.resp_body, [{:keys, :atoms}])
    assert_schema(json_body, "VolumeList", api_spec)
    json_body
  end

  def compare_environment_output(output, expected_envvars) do
    output_envs = TestHelper.from_environment_output(output)
    expected_envs = TestHelper.jail_environment(expected_envvars)
    assert output_envs == expected_envs
  end

  def jail_environment(additional_envs) do
    MapSet.new(
      [
        "LANG=C.UTF-8",
        "MAIL=/var/mail/root",
        "PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin:/root/bin",
        "PWD=/root",
        "TERM=screen",
        "USER=root",
        "HOME=/root",
        "SHELL=/bin/csh",
        "MM_CHARSET=UTF-8",
        "BLOCKSIZE=K"
      ] ++ additional_envs
    )
  end

  def from_environment_output(output) do
    MapSet.new(String.split(Enum.join(output), "\n", trim: true))
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

  def receive_frames(conn, timeout \\ 30_000) do
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

  def receive_frame(conn, timeout) do
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

        # unknown ->
        #  Logger.warn("unknown message received: #{inspect(unknown)}")
        #  receive_frame(conn, timeout)
    after
      timeout -> {:error, "timed out while waiting for websocket frames"}
    end
  end

  def now() do
    :timer.sleep(10)
    DateTime.to_iso8601(DateTime.utc_now())
  end

  def devfs_mounted(%Schemas.Container{dataset: dataset}) do
    :timer.sleep(500)
    mountpoint = ZFS.mountpoint(dataset)
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
