defmodule Kleened.Core.Image do
  alias Kleened.Core.{ZFS, MetaData, Utils, Layer, Network, OS, Container}
  alias Kleened.API.Schemas
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
              instructions: nil,
              total_steps: nil,
              container: nil,
              quiet: false
  end

  @type t() :: %Schemas.Image{}

  @spec build(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, pid()} | {:error, String.t()}
  def build(context_path, dockerfile, tag, buildargs, quiet \\ false) do
    {name, tag} = Kleened.Core.Utils.decode_tagname(tag)
    dockerfile_path = Path.join(context_path, dockerfile)
    {:ok, dockerfile} = File.read(dockerfile_path)
    instructions = Kleened.Core.Dockerfile.parse(dockerfile)

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
          container: %Schemas.Container{env: []},
          network: buildnet.id,
          buildargs_supplied: buildargs,
          buildargs_collected: [],
          msg_receiver: self(),
          current_step: 1,
          instructions: instructions,
          total_steps: length(instructions)
        }

        pid = Process.spawn(fn -> process_instructions(state) end, [:link])
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

  defp process_instructions(%State{instructions: [{line, {:from, image_ref}} | rest]} = state) do
    Logger.info("Processing instruction: FROM #{image_ref}")
    state = send_status(line, state)

    on_success = fn new_image_ref ->
      %Schemas.Image{id: image_id} = Kleened.Core.MetaData.get_image(new_image_ref)

      {:ok, container_config} =
        OpenApiSpex.Cast.cast(
          Kleened.API.Schemas.ContainerConfig.schema(),
          %{
            jail_param: ["mount.devfs=true"],
            image: image_id,
            user: "root",
            networks: %{state.network => %Schemas.EndPointConfig{container: "dummy"}},
            cmd: []
          }
        )

      name = Utils.uuid()

      {:ok, container} = Kleened.Core.Container.create(name, container_config)

      process_instructions(%State{state | container: container, instructions: rest})
    end

    environment_replacement(image_ref, on_success, state)
  end

  defp process_instructions(
         %State{instructions: [{line, {:env, env_vars}} | rest], container: container} = state
       ) do
    Logger.info("Processing instruction: ENV #{inspect(env_vars)}")
    state = send_status(line, state)

    on_success = fn env_vars ->
      env = Utils.merge_environment_variable_lists(container.env, [env_vars])

      process_instructions(%State{
        state
        | instructions: rest,
          container: %Schemas.Container{container | env: env}
      })
    end

    environment_replacement(env_vars, on_success, state)
  end

  defp process_instructions(
         %State{instructions: [{line, {:arg, buildarg}} | rest], buildargs_collected: buildargs} =
           state
       ) do
    Logger.info("Processing instruction: ARG #{buildarg}")
    state = send_status(line, state)
    buildargs = Utils.envlist2map(buildargs)
    buildarg = Utils.envlist2map([buildarg])
    buildargs = Map.merge(buildargs, buildarg)

    process_instructions(%State{
      state
      | instructions: rest,
        buildargs_collected: Utils.map2envlist(buildargs)
    })
  end

  defp process_instructions(%State{instructions: [{line, {:user, user}} | rest]} = state) do
    Logger.info("Processing instruction: USER #{user}")
    state = send_status(line, state)

    on_succes = fn user ->
      process_instructions(%State{
        state
        | instructions: rest,
          container: %Schemas.Container{state.container | user: user}
      })
    end

    environment_replacement(user, on_succes, state)
  end

  defp process_instructions(
         %State{instructions: [{line, {:cmd, cmd}} | rest], container: container} = state
       ) do
    Logger.info("Processing instruction: CMD #{inspect(cmd)}")
    state = send_status(line, state)

    process_instructions(%State{
      state
      | instructions: rest,
        container: %Schemas.Container{container | command: cmd}
    })
  end

  defp process_instructions(
         %State{instructions: [{line, {:run, cmd}} | _rest], container: container} = state
       ) do
    Logger.info("Processing instruction: RUN #{inspect(cmd)}")
    state = send_status(line, state)

    config = %Schemas.ExecConfig{
      container_id: container.id,
      cmd: cmd,
      env: create_environment_variables(state),
      user: container.user
    }

    exit_code = execute_cmd(config, state)
    validate_result_and_continue_if_valid(exit_code, state)
  end

  defp process_instructions(%State{instructions: [{line, {:copy, src_dest}} | _rest]} = state) do
    Logger.info("Processing instruction: COPY #{inspect(src_dest)}")
    state = send_status(line, state)
    # TODO Elixir have nice wildcard-expansion stuff that we could use here
    case environment_replacementsrc_dest(src_dest, [], state) do
      {:ok, src_and_dest} ->
        src_and_dest = convert_paths_to_jail_context_dir(src_and_dest)
        context_in_jail = create_context_dir_in_jail(state.context, state.container)

        config = %Schemas.ExecConfig{
          container_id: state.container.id,
          cmd: ["/bin/cp", "-R" | src_and_dest],
          env: [],
          user: "root"
        }

        exit_code = execute_cmd(config, state)
        unmount_context(context_in_jail)
        validate_result_and_continue_if_valid(exit_code, state)

      :failed ->
        send_substitution_failure_and_cleanup(state)
    end
  end

  defp process_instructions(
         %State{
           instructions: [],
           container: %Schemas.Container{
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
    Kleened.Core.Layer.to_image(layer, container_id)

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

    Kleened.Core.MetaData.add_image(img)
    send_msg(state.msg_receiver, {:image_build_succesfully, img})
  end

  defp environment_replacementsrc_dest([expression | rest], evaluated, state) do
    on_succes = fn evaluated_expr ->
      environment_replacementsrc_dest(rest, [evaluated_expr | evaluated], state)
    end

    environment_replacement(expression, on_succes, state)
  end

  defp environment_replacementsrc_dest([], evaluated, _state) do
    {:ok, Enum.reverse(evaluated)}
  end

  defp validate_result_and_continue_if_valid(0, %State{instructions: [_ | rest]} = state) do
    process_instructions(%State{state | instructions: rest})
  end

  defp validate_result_and_continue_if_valid(
         _nonzero_exit_code,
         %State{instructions: [{line, _instruction} | _]} = state
       ) do
    send_msg(state.msg_receiver, {:image_build_failed, line})
    cleanup_build_environment(state)
  end

  defp cleanup_build_environment(state) do
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

  defp environment_replacement(
         expression,
         on_success,
         %State{
           buildargs_collected: args_collected,
           buildargs_supplied: args_supplied,
           container: %Schemas.Container{env: env}
         } = state
       ) do
    args = merge_buildargs(args_supplied, args_collected)
    env = Utils.merge_environment_variable_lists(args, env)
    command = ~w"/usr/bin/env -i" ++ env ++ ["/bin/sh", "-c", "echo -n #{expression}"]

    case OS.cmd(command) do
      {evaluated_expression, 0} ->
        on_success.(evaluated_expression)

      {_, _nonzero_exit_code} ->
        send_substitution_failure_and_cleanup(state)
    end
  end

  defp send_substitution_failure_and_cleanup(
         %State{
           instructions: [{line, _instruction} | _rest],
           msg_receiver: pid
         } = state
       ) do
    send_msg(pid, {:image_build_failed, "failed environment substition of: #{line}"})

    cleanup_build_environment(state)
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
    {:ok, exec_id} = Kleened.Core.Exec.create(config)
    Kleened.Core.Exec.start(exec_id, %{attach: true, start_container: true})
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
    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    context_in_jail = Path.join(mountpoint, "/kleene_temporary_context_store")
    {_output, 0} = System.cmd("/bin/mkdir", [context_in_jail], stderr_to_stdout: true)
    Utils.mount_nullfs([context, context_in_jail])
    context_in_jail
  end

  defp convert_paths_to_jail_context_dir(srcdest) do
    {dest, relative_sources} = List.pop_at(srcdest, -1)

    sources =
      Enum.map(relative_sources, fn src -> Path.join("/kleene_temporary_context_store", src) end)

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
