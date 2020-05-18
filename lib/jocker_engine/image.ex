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

    %State{:image => image(layer_id: layer_id) = image} =
      Enum.reduce(instructions, state, &process_instructions/2)

    layer = Jocker.Engine.MetaData.get_layer(layer_id)
    Jocker.Engine.Layer.finalize(layer)
    now = DateTime.to_iso8601(DateTime.utc_now())
    {:ok, image(image, created: now)}
  end

  defp process_instructions({:from, image_id}, state) do
    image(layer_id: parent_layer_id) = parent_image = Jocker.Engine.MetaData.get_image(image_id)
    parent_layer = Jocker.Engine.MetaData.get_layer(parent_layer_id)
    layer(id: new_layer_id) = Jocker.Engine.Layer.initialize(parent_layer)
    # Create a new image-record that is going to be our newly created image.
    # it is going to be used as a reference for the RUN instructions issued during image build
    # and therefore we add it to the metadata database now.
    build_image =
      image(parent_image,
        layer_id: new_layer_id,
        name: :none,
        tag: :none,
        id: Jocker.Engine.Utils.uuid(),
        created: :none
      )

    Jocker.Engine.MetaData.add_image(build_image)
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
    image(id: img_id) = state.image

    opts = [
      image: img_id,
      user: state.user,
      overwrite: true,
      cmd: cmd
    ]

    {:ok, pid} = Jocker.Engine.ContainerPool.create(opts)
    Jocker.Engine.Container.attach(pid)
    Jocker.Engine.Container.start(pid)

    receive do
      {:container, ^pid, {:shutdown, :jail_stopped}} -> :ok
    end

    state
  end

  defp copy_files(context, srcdest, image(layer_id: layer_id)) do
    # FIXME Elixir have nice wildcard-expansion stuff that we could use here
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    {relative_dest, relative_sources} = List.pop_at(srcdest, -1)
    sources = Enum.map(relative_sources, fn src -> Path.join(context, src) end)
    dest = Path.join(mountpoint, relative_dest)
    args = Enum.reverse([dest | sources])
    {_output, 0} = System.cmd("/bin/cp", ["-R" | args])
  end
end
