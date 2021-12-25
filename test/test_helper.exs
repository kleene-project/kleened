alias Jocker.Engine.{ZFS, Config, Container, Layer}
require Logger

ExUnit.start()

ExUnit.configure(
  seed: 0,
  trace: true,
  max_failures: 1
)

defmodule TestHelper do
  def create_container(name, config) when not is_map_key(config, :image) do
    create_container(name, Map.put(config, :image, "base"))
  end

  def create_container(name, config) when not is_map_key(config, :jail_param) do
    create_container(name, Map.put(config, :jail_param, ["mount.devfs=true"]))
  end

  def create_container(name, config) when not is_map_key(config, :networks) do
    create_container(name, Map.put(config, :networks, ["default"]))
  end

  def create_container(name, config) do
    {:ok, container_config} =
      OpenApiSpex.Cast.cast(
        Jocker.Engine.API.Schemas.ContainerConfig.schema(),
        config
      )

    Container.create(name, container_config)
  end

  def start_attached_container(name, config) do
    {:ok, %Container{id: id} = cont} = create_container(name, config)
    :ok = Container.attach(id)
    Container.start(id)
    cont
  end

  def collect_container_output(id) do
    output = collect_container_output_(id, [])
    output |> Enum.reverse() |> Enum.join("")
  end

  defp collect_container_output_(id, output) do
    receive do
      {:container, ^id, {:shutdown, :jail_stopped}} ->
        output

      {:container, ^id, {:jail_output, msg}} ->
        collect_container_output_(id, [msg | output])

      {:container, ^id, msg} ->
        collect_container_output_(id, [msg | output])

      unknown ->
        IO.puts(
          "\nUnknown message received while collecting container output: #{inspect(unknown)}"
        )
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
    quiet = true
    {:ok, pid} = Jocker.Engine.Image.build(context, dockerfile, tag, quiet)
    {img, _messages} = receive_imagebuilder_results(pid, [])
    img
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
