defmodule Jocker.Image do
  # TODO: Need support for building multiple images from a set of instructions (i.e. a Dockerfile)
  # TODO: Need support for volumes
  import Jocker.Records

  defmodule State do
    defstruct context: nil,
              image: nil,
              user: nil
  end

  def create_image(instructions, context \\ "./") do
    state = %State{
      :context => context,
      :user => "root"
    }

    %State{:image => image(layer: layer) = image} =
      Enum.reduce(instructions, state, &process_instructions/2)

    finalized_layer = Jocker.Layer.finalize(layer)
    now = :erlang.timestamp()
    image(image, layer: finalized_layer, created: now)
  end

  defp process_instructions({:from, image_id}, state) do
    image(layer: parent_layer) = parent_image = Jocker.MetaData.get_image(image_id)
    new_layer = Jocker.Layer.initialize(parent_layer)
    # TODO: Consider using the layer-id instead of generating a new one
    build_image = image(parent_image, layer: new_layer, id: Jocker.Utils.uuid(), created: :none)
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

    {:ok, pid} = Jocker.ContainerPool.create(opts)
    Jocker.Container.attach(pid)
    Jocker.Container.start(pid)

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
    {output, 0} = System.cmd("/bin/cp", ["-R" | args])
  end
end
