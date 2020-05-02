defmodule Jocker.Engine.Image do
  # TODO: Need support for building multiple images from a set of instructions (i.e. a Dockerfile)
  # TODO: Need support for volumes
  import Jocker.Engine.Records

  defmodule State do
    defstruct context: nil,
              image: nil,
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

  def create_image(instructions, context \\ "./") do
    state = %State{
      :context => context,
      :user => "root"
    }

    %State{:image => image(layer: layer) = image} =
      Enum.reduce(instructions, state, &process_instructions/2)

    finalized_layer = Jocker.Engine.Layer.finalize(layer)
    now = DateTime.to_iso8601(DateTime.utc_now())
    {:ok, image(image, layer: finalized_layer, created: now)}
  end

  defp process_instructions({:from, image_id}, state) do
    image(layer: parent_layer) = parent_image = Jocker.Engine.MetaData.get_image(image_id)
    new_layer = Jocker.Engine.Layer.initialize(parent_layer)
    # TODO: Consider using the layer-id instead of generating a new one
    build_image =
      image(parent_image, layer: new_layer, id: Jocker.Engine.Utils.uuid(), created: :none)

    %State{state | image: build_image}
  end

  defp process_instructions({:copy, src_and_dest}, state) do
    copy_files(state.context, src_and_dest, state.image)
    state
  end

  defp process_instructions({:user, user}, %State{:image => image} = state) do
    %State{state | :image => image(image, user: user)}
  end

  defp process_instructions({:cmd, cmd}, %State{:image => image} = state) do
    %State{state | :image => image(image, command: cmd)}
  end

  defp process_instructions({:run, cmd}, state) do
    opts = [
      image: state.image,
      user: state.user,
      overwrite: true,
      cmd: cmd
    ]

    {:ok, pid} = Jocker.Engine.ContainerPool.create(opts)
    Jocker.Engine.Container.attach(pid)
    Jocker.Engine.Container.start(pid)

    receive do
      {:container, ^pid, "jail stopped"} -> :ok
    end

    state
  end

  defp copy_files(context, srcdest, image(layer: layer(mountpoint: mountpoint))) do
    # FIXME Elixir have nice wildcard-expansion stuff that we could use here
    {relative_dest, relative_sources} = List.pop_at(srcdest, -1)
    sources = Enum.map(relative_sources, fn src -> Path.join(context, src) end)
    dest = Path.join(mountpoint, relative_dest)
    args = Enum.reverse([dest | sources])
    {_output, 0} = System.cmd("/bin/cp", ["-R" | args])
  end
end