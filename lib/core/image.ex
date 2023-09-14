defmodule Kleened.Core.Image do
  alias Kleened.Core.{ZFS, MetaData, Utils, Layer, Network, OS, Container}
  alias Kleened.API.Schemas
  require Logger

  defmodule State do
    defstruct build_id: nil,
              context: nil,
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
              workdir: nil,
              cleanup: true,
              quiet: false
  end

  @type t() :: %Schemas.Image{}

  @spec build(String.t(), String.t(), String.t(), String.t(), boolean(), boolean()) ::
          {:ok, pid()} | {:error, String.t()}
  def build(build_id, context_path, dockerfile, tag, buildargs, cleanup, quiet \\ false) do
    {name, tag} = Kleened.Core.Utils.decode_tagname(tag)
    dockerfile_path = Path.join(context_path, dockerfile)
    {:ok, dockerfile} = File.read(dockerfile_path)
    instructions = Kleened.Core.Dockerfile.parse(dockerfile)

    case verify_instructions(instructions) do
      :ok ->
        {:ok, buildnet} =
          Network.create(%Schemas.NetworkConfig{
            name: "build" <> build_id,
            subnet: "172.18.0.0/24",
            ifname: build_id,
            driver: "loopback"
          })

        state = %State{
          build_id: build_id,
          context: context_path,
          image_name: name,
          image_tag: tag,
          network: buildnet.id,
          buildargs_supplied: buildargs,
          buildargs_collected: [],
          msg_receiver: self(),
          current_step: 1,
          instructions: instructions,
          total_steps: length(instructions),
          container: %Schemas.Container{env: []},
          workdir: "/",
          cleanup: cleanup,
          quiet: quiet
        }

        pid = Process.spawn(fn -> process_instructions(state) end, [:link])
        {:ok, build_id, pid}

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

  defp verify_instructions([{line, {:error, reason}} | _rest]) do
    {:error, "error in '#{line}': #{reason}"}
  end

  defp verify_instructions([{_line, _instruction} | rest]) do
    verify_instructions(rest)
  end

  defp process_instructions(%State{instructions: [{line, {:from, image_ref}} | rest]} = state) do
    Logger.info("Processing instruction: FROM #{image_ref}")
    state = send_status(line, state)

    with {:ok, new_image_ref} <- environment_replacement(image_ref, state),
         %Schemas.Image{id: image_id} <- Kleened.Core.MetaData.get_image(new_image_ref) do
      {:ok, container_config} =
        OpenApiSpex.Cast.cast(
          Schemas.ContainerConfig.schema(),
          %{
            jail_param: ["mount.devfs=true"],
            image: image_id,
            user: "root",
            cmd: [],
            env: []
          }
        )

      name = "build_" <> state.build_id
      {:ok, container} = Kleened.Core.Container.create(name, container_config)
      Network.connect(state.network, %Schemas.EndPointConfig{container: container.id})
      process_instructions(%State{state | container: container, instructions: rest})
    else
      :not_found ->
        send_msg(state.msg_receiver, "parent image not found")
        terminate_failed_build(state)

      _ ->
        terminate_failed_build(state)
    end
  end

  defp process_instructions(
         %State{instructions: [{line, {:env, env_vars}} | rest], container: container} = state
       ) do
    Logger.info("Processing instruction: ENV #{inspect(env_vars)}")
    state = send_status(line, state)

    case environment_replacement(env_vars, state) do
      {:ok, new_env_vars} ->
        env = Utils.merge_environment_variable_lists(container.env, [new_env_vars])

        process_instructions(%State{
          state
          | instructions: rest,
            container: %Schemas.Container{container | env: env}
        })

      :error ->
        terminate_failed_build(state)
    end
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

    case environment_replacement(user, state) do
      {:ok, new_user} ->
        process_instructions(%State{
          state
          | instructions: rest,
            container: %Schemas.Container{state.container | user: new_user}
        })

      :error ->
        terminate_failed_build(state)
    end
  end

  defp process_instructions(%State{instructions: [{line, {:workdir, workdir}} | rest]} = state) do
    Logger.info("Processing instruction: WORKDIR #{inspect(workdir)}")
    state = send_status(line, state)

    new_workdir =
      case String.starts_with?(workdir, "/") do
        true -> workdir
        false -> Path.join(state.workdir, workdir)
      end

    config_mkdir = %Schemas.ExecConfig{
      container_id: state.container.id,
      cmd: ["/bin/mkdir", "-p", new_workdir],
      env: [],
      user: "root"
    }

    case succesfully_run_execution(config_mkdir, state) do
      :ok -> process_instructions(%State{state | workdir: new_workdir, instructions: rest})
      :error -> terminate_failed_build(state)
    end
  end

  defp process_instructions(
         %State{instructions: [{line, {:cmd, cmd}} | rest], container: container} = state
       ) do
    Logger.info("Processing instruction: CMD #{inspect(cmd)}")
    state = send_status(line, state)
    new_container = %Schemas.Container{container | command: cmd}
    process_instructions(%State{state | instructions: rest, container: new_container})
  end

  defp process_instructions(
         %State{instructions: [{line, {:run, cmd}} | rest], container: container} = state
       ) do
    Logger.info("Processing instruction: RUN #{inspect(cmd)}")
    state = send_status(line, state)

    cmd = adapt_run_command_to_workdir(cmd, state.workdir)

    config = %Schemas.ExecConfig{
      container_id: container.id,
      cmd: cmd,
      env: create_environment_variables(state),
      user: container.user
    }

    case succesfully_run_execution(config, state) do
      :ok -> process_instructions(%State{state | instructions: rest})
      :error -> terminate_failed_build(state)
    end
  end

  defp process_instructions(%State{instructions: [{line, {:copy, src_dest}} | rest]} = state) do
    Logger.info("Processing instruction: COPY #{inspect(src_dest)}")
    state = send_status(line, state)
    context_in_jail = context_directory_in_container(state.container)

    with {:ok, src_and_dest} <- environment_replacement_list(src_dest, [], state),
         {config_mkdir, config_cp} = copy_instruction_exec_configs(src_and_dest, state),
         :ok <- mount_context(context_in_jail, state),
         :ok <- succesfully_run_execution(config_mkdir, state),
         :ok <- succesfully_run_execution(config_cp, state) do
      unmount_context(context_in_jail)
      process_instructions(%State{state | instructions: rest})
    else
      _error ->
        unmount_context(context_in_jail)
        terminate_failed_build(state)
    end
  end

  defp process_instructions(
         %State{
           # No more instructions
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
    {:ok, _network_id} = Network.remove(state.network)
    MetaData.delete_container(container_id)
    layer = MetaData.get_layer(layer_id)
    Kleened.Core.Layer.to_image_from_layer(layer, container_id)

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

  defp terminate_failed_build(%State{container: %Schemas.Container{id: nil}} = state) do
    Network.remove(state.network)
    send_msg(state.msg_receiver, {:image_build_failed, "image build failed"})
  end

  defp terminate_failed_build(state) do
    cond do
      state.cleanup -> Container.remove(state.container.id)
      true -> :ok
    end

    Network.remove(state.network)
    send_msg(state.msg_receiver, {:image_build_failed, "image build failed"})
  end

  defp environment_replacement_list([expression | rest], evaluated, state) do
    case environment_replacement(expression, state) do
      {:ok, evaluated_expr} ->
        environment_replacement_list(rest, [evaluated_expr | evaluated], state)

      :error ->
        :error
    end
  end

  defp environment_replacement_list([], evaluated, _state) do
    {:ok, Enum.reverse(evaluated)}
  end

  defp environment_replacement(
         expression,
         %State{
           instructions: [{line, _instruction} | _rest],
           msg_receiver: pid,
           buildargs_collected: args_collected,
           buildargs_supplied: args_supplied,
           container: %Schemas.Container{env: env}
         }
       ) do
    args = merge_buildargs(args_supplied, args_collected)
    env = Utils.merge_environment_variable_lists(args, env)
    command = ~w"/usr/bin/env -i" ++ env ++ ["/bin/sh", "-c", "echo -n #{expression}"]

    case OS.cmd(command) do
      {evaluated_expression, 0} ->
        {:ok, evaluated_expression}

      {_, _nonzero_exit_code} ->
        send_msg(pid, "failed environment substition of: #{line}")
        :error
    end
  end

  defp create_environment_variables(%State{
         buildargs_collected: args_collected,
         buildargs_supplied: args_supplied,
         container: %Schemas.Container{env: env}
       }) do
    args = merge_buildargs(args_supplied, args_collected)
    Utils.merge_environment_variable_lists(args, env)
  end

  defp merge_buildargs(args_supplied, args_collected) when is_list(args_collected) do
    args_collected = Utils.envlist2map(args_collected)
    merge_buildargs(args_supplied, args_collected)
  end

  defp merge_buildargs([arg_supplied | rest], args_collected) when is_map(args_collected) do
    [name, value] = String.split(arg_supplied, "=", parts: 2)

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

  defp succesfully_run_execution(config, %State{msg_receiver: pid} = state) do
    case run_execution(config, state) do
      0 ->
        :ok

      nonzero_exitcode ->
        cmd = Enum.join(config.cmd, " ")
        send_msg(pid, "The command '#{cmd}' returned a non-zero code: #{nonzero_exitcode}")
        :error
    end
  end

  defp run_execution(%Schemas.ExecConfig{container_id: id} = config, state) do
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

  defp adapt_run_command_to_workdir(cmd, workdir) do
    case {cmd, workdir} do
      {{_cmd_type, cmd}, "/"} ->
        cmd

      {{:shell_form, ["/bin/sh", "-c", cmd]}, workdir} ->
        ["/bin/sh", "-c", "cd #{workdir} && #{cmd}"]

      {{:exec_form, cmd}, _} ->
        cmd
    end
  end

  defp copy_instruction_exec_configs(src_and_dest, state) do
    src_and_dest = wildcard_expand_srcs(src_and_dest, state)
    src_and_dest = convert_paths_to_jail_context_dir_and_workdir(src_and_dest, state.workdir)

    # Create <dest> directory if it does not exist
    dest = List.last(src_and_dest)

    config_mkdir = %Schemas.ExecConfig{
      container_id: state.container.id,
      cmd: ["/bin/mkdir", "-p", dest],
      env: [],
      user: "root"
    }

    config_cp = %Schemas.ExecConfig{
      container_id: state.container.id,
      cmd: ["/bin/cp", "-R" | src_and_dest],
      env: [],
      user: "root"
    }

    {config_mkdir, config_cp}
  end

  defp context_directory_in_container(%Schemas.Container{layer_id: layer_id}) do
    %Layer{mountpoint: mountpoint} = Kleened.Core.MetaData.get_layer(layer_id)
    Path.join(mountpoint, "/kleene_temporary_context_store")
  end

  defp wildcard_expand_srcs(srcdest, state) do
    {dest, srcs_relative} = List.pop_at(srcdest, -1)
    context_depth = length(Path.split(state.context))

    expanded_sources =
      Enum.flat_map(srcs_relative, fn src_rel ->
        # Wildcard-expand on the hosts absolute paths
        src_expanded_list = Path.join(state.context, src_rel) |> Path.wildcard()

        # Remove context-root from expanded paths
        Enum.map(src_expanded_list, &(Path.split(&1) |> Enum.drop(context_depth) |> Path.join()))
      end)

    Enum.reverse([dest | expanded_sources])
  end

  defp convert_paths_to_jail_context_dir_and_workdir(srcdest, workdir) do
    {dest, relative_sources} = List.pop_at(srcdest, -1)
    dest = Path.join(workdir, dest)

    absolute_sources =
      Enum.map(relative_sources, fn src -> Path.join("/kleene_temporary_context_store", src) end)

    Enum.reverse([dest | absolute_sources])
  end

  defp mount_context(context_in_jail, %State{msg_receiver: pid} = state) do
    # Create a context-directory within the container and nullfs-mount the context into it
    with {_, 0} <- System.cmd("/bin/mkdir", [context_in_jail], stderr_to_stdout: true),
         {_, 0} <- Utils.mount_nullfs([state.context, context_in_jail]) do
      :ok
    else
      {output, _nonzero_exitcode} ->
        send_msg(pid, "could not create context mountpoint in container: #{output}")
        :error
    end
  end

  defp unmount_context(context_in_jail) do
    case File.exists?(context_in_jail) do
      true ->
        Utils.unmount(context_in_jail)
        System.cmd("/bin/rm", ["-r", context_in_jail], stderr_to_stdout: true)

      false ->
        :ok
    end
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

  defp send_msg(pid, msg) do
    full_msg = {:image_builder, self(), msg}
    :ok = Process.send(pid, full_msg, [])
  end
end
