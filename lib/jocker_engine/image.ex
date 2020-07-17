defmodule Jocker.Engine.Image do
  # TODO: Need support for building multiple images from a set of instructions (i.e. a Dockerfile)
  # TODO: Need support for volumes
  import Jocker.Engine.Records
  alias Jocker.Engine.ZFS
  alias Jocker.Engine.MetaData
  require Logger

  defmodule State do
    defstruct context: nil,
              image: nil,
              container: nil,
              user: nil
  end

  def build_image_from_file(dockerfile_path, {name, tag}, context) do
    {:ok, dockerfile} = File.read(dockerfile_path)
    instructions = Jocker.Engine.Dockerfile.parse(dockerfile)
    {:ok, img_raw} = create_image(instructions, context)
    img = image(img_raw, name: name, tag: tag)
    Jocker.Engine.MetaData.add_image(img)
    {:ok, img}
  end

  @spec destroy(String.t()) :: :ok | :not_found
  def destroy(id_or_nametag) do
    case MetaData.get_image(id_or_nametag) do
      :not_found ->
        :not_found

      image(id: id, layer_id: layer_id) ->
        layer(dataset: dataset) = MetaData.get_layer(layer_id)
        0 = ZFS.destroy_force(dataset)
        MetaData.delete_image(id)
    end
  end

  def create_image(instructions, context \\ "./") do
    state = %State{
      :context => context,
      :user => "root"
    }

    %State{:container => cont} = Enum.reduce(instructions, state, &process_instructions/2)

    container(id: image_id, layer_id: layer_id, user: user, command: cmd) = cont

    MetaData.delete_container(cont)
    layer = MetaData.get_layer(layer_id)
    Jocker.Engine.Layer.finalize(layer)

    img =
      image(
        id: image_id,
        layer_id: layer_id,
        user: user,
        command: cmd,
        created: DateTime.to_iso8601(DateTime.utc_now())
      )

    Jocker.Engine.MetaData.add_image(img)
    {:ok, img}
  end

  defp process_instructions({:from, image_reference}, state) do
    Logger.info("Processing instruction: FROM #{image_reference}")
    image(id: image_id, user: user) = Jocker.Engine.MetaData.get_image(image_reference)

    opts = [
      jail_param: ["mount.devfs=true"],
      image: image_id,
      user: user,
      cmd: []
    ]

    {:ok, container(pid: pid) = cont} = Jocker.Engine.Container.create(opts)
    :ok = Jocker.Engine.Container.stop(pid)
    %State{state | image: image_id, container: cont, user: user}
  end

  defp process_instructions({:copy, src_and_dest}, %State{:container => cont} = state) do
    Logger.info("Processing instruction: COPY #{inspect(src_and_dest)}")
    copy_files(state.context, src_and_dest, cont)
    state
  end

  defp process_instructions({:user, user}, state) do
    Logger.info("Processing instruction: USER #{user}")
    %State{state | :user => user}
  end

  defp process_instructions({:cmd, cmd}, %State{:container => cont} = state) do
    Logger.info("Processing instruction: CMD #{inspect(cmd)}")
    %State{state | :container => container(cont, command: cmd)}
  end

  defp process_instructions({:run, cmd}, state) do
    Logger.info("Processing instruction: RUN #{inspect(cmd)}")
    container(id: container_id) = state.container

    {:ok, container(pid: pid)} =
      Jocker.Engine.Container.create(
        existing_container: container_id,
        user: state.user,
        cmd: cmd
      )

    Jocker.Engine.Container.attach(pid)
    Jocker.Engine.Container.start(pid)

    receive do
      {:container, ^pid, {:shutdown, :jail_stopped}} -> :ok
    end

    state
  end

  defp copy_files(context, srcdest, container(layer_id: layer_id)) do
    # TODO Elixir have nice wildcard-expansion stuff that we could use here
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    {relative_dest, relative_sources} = List.pop_at(srcdest, -1)
    sources = Enum.map(relative_sources, fn src -> Path.join(context, src) end)
    dest = Path.join(mountpoint, relative_dest)
    args = Enum.reverse([dest | sources])
    {_output, 0} = System.cmd("/bin/cp", ["-R" | args])
  end
end
