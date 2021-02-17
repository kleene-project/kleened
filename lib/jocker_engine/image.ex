defmodule Jocker.Engine.Image do
  # TODO: Need support for volumes
  import Jocker.Engine.Records
  alias Jocker.Engine.ZFS
  alias Jocker.Engine.MetaData
  alias Jocker.Engine.Utils
  require Logger

  defmodule State do
    defstruct context: nil,
              image_name: nil,
              image_tag: nil,
              msg_receiver: nil,
              current_step: nil,
              total_steps: nil,
              container: nil,
              user: nil,
              quiet: false
  end

  @spec build(String.t(), String.t(), String.t(), boolean()) :: {:ok, pid()}
  def build(context, dockerfile, tag, quiet \\ false) do
    {name, tag} = Jocker.Engine.Utils.decode_tagname(tag)
    dockerfile_path = Path.join(context, dockerfile)
    {:ok, dockerfile} = File.read(dockerfile_path)
    instructions = Jocker.Engine.Dockerfile.parse(dockerfile)

    state = %State{
      :context => context,
      :user => "root",
      :quiet => quiet,
      :image_name => name,
      :image_tag => tag,
      :msg_receiver => self(),
      :current_step => 1,
      :total_steps => length(instructions)
    }

    pid = Process.spawn(fn -> create_image(instructions, state) end, [])
    {:ok, pid}
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

  def create_image(instructions, state) do
    %State{:container => cont} = Enum.reduce(instructions, state, &process_instructions/2)
    container(id: container_id, layer_id: layer_id, user: user, command: cmd) = cont
    Jocker.Engine.Network.disconnect(container_id, "default")
    MetaData.delete_container(container_id)
    layer = MetaData.get_layer(layer_id)
    Jocker.Engine.Layer.to_image(layer, container_id)

    img =
      image(
        id: container_id,
        layer_id: layer_id,
        user: user,
        name: state.image_name,
        tag: state.image_tag,
        command: cmd,
        created: DateTime.to_iso8601(DateTime.utc_now())
      )

    Jocker.Engine.MetaData.add_image(img)
    send_msg(state.msg_receiver, {:image_finished, img})
  end

  defp process_instructions({line, {:from, image_reference}}, state) do
    Logger.info("Processing instruction: FROM #{image_reference}")
    state = send_status(line, state)
    image(id: image_id, user: user) = Jocker.Engine.MetaData.get_image(image_reference)

    opts = [
      jail_param: ["mount.devfs=true"],
      image: image_id,
      user: user,
      cmd: []
    ]

    {:ok, cont} = Jocker.Engine.Container.create(opts)
    %State{state | :container => cont, :user => user}
  end

  defp process_instructions({line, {:copy, src_and_dest}}, state) do
    # TODO Elixir have nice wildcard-expansion stuff that we could use here
    Logger.info("Processing instruction: COPY #{inspect(src_and_dest)}")
    state = send_status(line, state)
    context_in_jail = create_context_dir_in_jail(state.context, state.container)
    src_and_dest = convert_paths_to_jail_context_dir(src_and_dest)
    execute_cmd(["/bin/cp", "-R" | src_and_dest], "root", state)
    unmount_context(context_in_jail)
    state
  end

  defp process_instructions({line, {:user, user}}, state) do
    Logger.info("Processing instruction: USER #{user}")
    state = send_status(line, state)
    %State{state | :user => user}
  end

  defp process_instructions({line, {:cmd, cmd}}, %State{:container => cont} = state) do
    Logger.info("Processing instruction: CMD #{inspect(cmd)}")
    state = send_status(line, state)
    %State{state | :container => container(cont, command: cmd)}
  end

  defp process_instructions({line, {:run, cmd}}, state) do
    Logger.info("Processing instruction: RUN #{inspect(cmd)}")
    state = send_status(line, state)
    execute_cmd(cmd, state.user, state)
    state
  end

  defp send_status(_line, %State{:quiet => true} = state) do
    state
  end

  defp send_status(
         line,
         %State{
           :current_step => step,
           :total_steps => nsteps,
           :msg_receiver => pid
         } = state
       ) do
    msg = "Step #{step}/#{nsteps} : #{line}\n"
    send_msg(pid, msg)
    %State{state | :current_step => step + 1}
  end

  defp execute_cmd(cmd, user, %State{:container => container(id: id)} = state) do
    Jocker.Engine.Container.attach(id)
    Jocker.Engine.Container.start(id, cmd: cmd, user: user)
    receive_shutdown(id, state)
  end

  defp receive_shutdown(id, state) do
    receive do
      {:container, ^id, {:shutdown, :jail_stopped}} ->
        :ok

      {:container, ^id, msg} ->
        if not state.quiet do
          send_msg(state.msg_receiver, msg)
        end

        receive_shutdown(id, state)

      other ->
        Logger.error("Weird stuff received: #{inspect(other)}")
    end
  end

  defp create_context_dir_in_jail(context, container(layer_id: layer_id)) do
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    context_in_jail = Path.join(mountpoint, "/jocker_temporary_context_store")
    {_output, 0} = System.cmd("/bin/mkdir", [context_in_jail], stderr_to_stdout: true)
    Utils.mount_nullfs([context, context_in_jail])
    context_in_jail
  end

  defp convert_paths_to_jail_context_dir(srcdest) do
    {dest, relative_sources} = List.pop_at(srcdest, -1)

    sources =
      Enum.map(relative_sources, fn src -> Path.join("/jocker_temporary_context_store", src) end)

    Enum.reverse([dest | sources])
  end

  defp send_msg(pid, msg) do
    full_msg = {:image_builder, self(), msg}
    :ok = Process.send(pid, full_msg, [])
  end

  defp unmount_context(context_in_jail) do
    Utils.unmount(context_in_jail)
    {_output, 0} = System.cmd("/bin/rm", ["-r", context_in_jail], stderr_to_stdout: true)
  end
end
