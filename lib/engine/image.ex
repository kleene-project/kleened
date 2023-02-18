defmodule Jocker.Engine.Image do
  alias Jocker.Engine.{ZFS, MetaData, Utils, Layer, Network, OS, Container}
  alias Jocker.API.Schemas
  require Logger

  defmodule State do
    defstruct context: nil,
              image_name: nil,
              image_tag: nil,
              network: nil,
              buildargs_supplied: nil,
              buildargs_collected: nil,
              msg_receiver: nil,
              current_step: nil,
              total_steps: nil,
              container: nil,
              quiet: false
  end

  @type t() :: %Schemas.Image{}

  @spec build(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, pid()} | {:error, String.t()}
  def build(context_path, dockerfile, tag, buildargs, quiet \\ false) do
    {name, tag} = Jocker.Engine.Utils.decode_tagname(tag)
    dockerfile_path = Path.join(context_path, dockerfile)
    {:ok, dockerfile} = File.read(dockerfile_path)
    instructions = Jocker.Engine.Dockerfile.parse(dockerfile)

    case verify_instructions(instructions) do
      :ok ->
        build_id = String.slice(Utils.uuid(), 0..5)

        {:ok, buildnet} =
          Network.create(%Schemas.NetworkConfig{
            name: "builder" <> build_id,
            subnet: "172.18.0.0/24",
            ifname: build_id,
            driver: "loopback"
          })

        state = %State{
          context: context_path,
          quiet: quiet,
          image_name: name,
          image_tag: tag,
          network: buildnet.id,
          buildargs_supplied: buildargs,
          buildargs_collected: [],
          msg_receiver: self(),
          current_step: 1,
          total_steps: length(instructions)
        }

        pid = Process.spawn(fn -> process_instructions(instructions, state) end, [:link])
        {:ok, pid}

      {:error, error_msg} ->
        {:error, error_msg}
    end
  end

  @spec destroy(String.t()) :: :ok | :not_found
  def destroy(id_or_nametag) do
    case MetaData.get_image(id_or_nametag) do
      :not_found ->
        :not_found

      %Schemas.Image{id: id, layer_id: layer_id} ->
        %Layer{dataset: dataset} = MetaData.get_layer(layer_id)
        {_, 0} = ZFS.destroy_force(dataset)
        MetaData.delete_image(id)
    end
  end

  defp verify_instructions([]) do
    :ok
  end

  defp verify_instructions([{line, {:env, {:error, msg}}} | _rest]) do
    {:error, "#{msg} on line: #{line}"}
  end

  defp verify_instructions([{line, {:arg, {:error, msg}}} | _rest]) do
    {:error, "#{msg} on line: #{line}"}
  end

  defp verify_instructions([{_line, {:unparsed, instruction_line}} | _rest]) do
    {:error, "invalid instruction: #{instruction_line}"}
  end

  defp verify_instructions([{_line, _instruction} | rest]) do
    verify_instructions(rest)
  end

  defp process_instructions([{line, {:from, image_reference}} | rest], state) do
    Logger.info("Processing instruction: FROM #{image_reference}")
    state = send_status(line, state)
    %Schemas.Image{id: image_id} = Jocker.Engine.MetaData.get_image(image_reference)

    {:ok, container_config} =
      OpenApiSpex.Cast.cast(
        Jocker.API.Schemas.ContainerConfig.schema(),
        %{
          jail_param: ["mount.devfs=true"],
          image: image_id,
          user: "root",
          networks: %{state.network => %Schemas.EndPointConfig{container: "dummy"}},
          cmd: []
        }
      )

    name = Utils.uuid()

    {:ok, cont} = Jocker.Engine.Container.create(name, container_config)
    process_instructions(rest, %State{state | :container => cont})
  end

  defp process_instructions(
         [{line, {:copy, src_and_dest}} | rest],
         %State{container: container, context: context} = state
       ) do
    # TODO Elixir have nice wildcard-expansion stuff that we could use here
    Logger.info("Processing instruction: COPY #{inspect(src_and_dest)}")
    state = send_status(line, state)
    context_in_jail = create_context_dir_in_jail(context, container)
    src_and_dest = Enum.map(src_and_dest, &shell_evaluate_instruction(&1, state))
    src_and_dest = convert_paths_to_jail_context_dir(src_and_dest)

    config = %Schemas.ExecConfig{
      container_id: container.id,
      cmd: ["/bin/cp", "-R" | src_and_dest],
      env: [],
      user: "root"
    }

    exit_code = execute_cmd(config, state)
    unmount_context(context_in_jail)
    validate_result_and_continue_if_valid(exit_code, rest, line, state)
  end

  defp process_instructions([{line, {:user, user}} | rest], state) do
    Logger.info("Processing instruction: USER #{user}")
    state = send_status(line, state)
    user = shell_evaluate_instruction(user, state)
    state = %State{state | container: %Schemas.Container{state.container | user: user}}
    process_instructions(rest, state)
  end

  defp process_instructions([{line, {:cmd, cmd}} | rest], %State{:container => cont} = state) do
    Logger.info("Processing instruction: CMD #{inspect(cmd)}")
    state = send_status(line, state)
    state = %State{state | :container => %Schemas.Container{cont | command: cmd}}
    process_instructions(rest, state)
  end

  defp process_instructions(
         [{line, {:arg, buildarg}} | rest],
         %State{buildargs_collected: buildargs} = state
       ) do
    Logger.info("Processing instruction: ARG #{buildarg}")
    state = send_status(line, state)
    buildargs = Utils.envlist2map(buildargs)
    buildarg = Utils.envlist2map([buildarg])
    buildargs = Map.merge(buildargs, buildarg)
    state = %State{state | buildargs_collected: Utils.map2envlist(buildargs)}
    process_instructions(rest, state)
  end

  defp process_instructions([{line, {:env, env_vars}} | rest], %State{:container => cont} = state) do
    Logger.info("Processing instruction: ENV #{inspect(env_vars)}")
    state = send_status(line, state)
    env_vars = shell_evaluate_instruction(env_vars, state)
    env = Utils.merge_environment_variable_lists(cont.env, [env_vars])
    state = %State{state | :container => %Schemas.Container{cont | env: env}}
    process_instructions(rest, state)
  end

  defp process_instructions([{line, {:run, cmd}} | rest], %State{container: container} = state) do
    Logger.info("Processing instruction: RUN #{inspect(cmd)}")
    state = send_status(line, state)
    env = create_environment_variables(state)

    config = %Schemas.ExecConfig{
      container_id: container.id,
      cmd: cmd,
      env: env,
      user: container.user
    }

    exit_code = execute_cmd(config, state)
    validate_result_and_continue_if_valid(exit_code, rest, line, state)
  end

  defp process_instructions(
         [],
         %State{
           :container => %Schemas.Container{
             id: container_id,
             layer_id: layer_id,
             user: user,
             env: env,
             command: cmd
           }
         } = state
       ) do
    Network.disconnect(container_id, state.network)
    Network.remove(state.network)
    MetaData.delete_container(container_id)
    layer = MetaData.get_layer(layer_id)
    Jocker.Engine.Layer.to_image(layer, container_id)

    img = %Schemas.Image{
      id: container_id,
      layer_id: layer_id,
      user: user,
      name: state.image_name,
      tag: state.image_tag,
      command: cmd,
      env: env,
      created: DateTime.to_iso8601(DateTime.utc_now())
    }

    Jocker.Engine.MetaData.add_image(img)
    send_msg(state.msg_receiver, {:image_build_succesfully, img})
  end

  defp validate_result_and_continue_if_valid(0, rest, _line, state) do
    process_instructions(rest, state)
  end

  defp validate_result_and_continue_if_valid(_nonzero_exit_code, _rest, line, state) do
    send_msg(state.msg_receiver, {:image_build_failed, line})
    Container.remove(state.container.id)
    Network.remove(state.network)
  end

  defp create_environment_variables(%State{
         buildargs_collected: args_collected,
         buildargs_supplied: args_supplied,
         container: %Schemas.Container{env: env}
       }) do
    args = merge_buildargs(args_supplied, args_collected)
    Utils.merge_environment_variable_lists(args, env)
  end

  defp shell_evaluate_instruction(string, %State{
         buildargs_collected: args_collected,
         buildargs_supplied: args_supplied,
         container: %Schemas.Container{env: env}
       }) do
    args = merge_buildargs(args_supplied, args_collected)
    env = Utils.merge_environment_variable_lists(args, env)
    command = ~w"/usr/bin/env -i" ++ env ++ ["/bin/sh", "-c", "echo -n #{string}"]
    {substituted_string, 0} = OS.cmd(command)
    substituted_string
  end

  defp merge_buildargs(args_supplied, args_collected) when is_list(args_collected) do
    args_collected = Utils.envlist2map(args_collected)
    merge_buildargs(args_supplied, args_collected)
  end

  defp merge_buildargs([buildarg | rest], args_collected) when is_map(args_collected) do
    [name, value] = String.split(buildarg, "=", parts: 2)

    args =
      case Map.has_key?(args_collected, name) do
        true ->
          Map.put(args_collected, name, value)

        false ->
          args_collected
      end

    merge_buildargs(rest, args)
  end

  defp merge_buildargs([], args_collected) do
    Utils.map2envlist(args_collected)
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

  defp execute_cmd(%Schemas.ExecConfig{container_id: id} = config, state) do
    {:ok, exec_id} = Jocker.Engine.Exec.create(config)
    Jocker.Engine.Exec.start(exec_id, %{attach: true, start_container: true})
    relay_output_and_await_shutdown(id, exec_id, state)
  end

  defp relay_output_and_await_shutdown(id, exec_id, state) do
    receive do
      {:container, ^exec_id, {:shutdown, {:jail_stopped, exit_code}}} ->
        exit_code

      {:container, ^exec_id, msg} ->
        if not state.quiet do
          send_msg(state.msg_receiver, msg)
        end

        relay_output_and_await_shutdown(id, exec_id, state)

      {:container, ^exec_id, {:jail_output, msg}} ->
        if not state.quiet do
          send_msg(state.msg_receiver, {:jail_output, msg})
        end

        relay_output_and_await_shutdown(id, exec_id, state)

      other ->
        Logger.error("Weird stuff received: #{inspect(other)}")
    end
  end

  defp create_context_dir_in_jail(context, %Schemas.Container{layer_id: layer_id}) do
    %Layer{mountpoint: mountpoint} = Jocker.Engine.MetaData.get_layer(layer_id)
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
    System.cmd("/bin/rm", ["-r", context_in_jail], stderr_to_stdout: true)
  end
end
