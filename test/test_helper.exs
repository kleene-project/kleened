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
