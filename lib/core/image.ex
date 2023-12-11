defmodule Kleened.Core.Image do
  alias Kleened.Core.{Const, ZFS, MetaData, Utils, Mount, Network, OS, Container, Config}
  alias Kleened.API.Schemas
  require Logger

  defmodule State do
    defstruct context: nil,
              image_id: nil,
              image_name: nil,
              image_tag: nil,
              network: nil,
              buildargs_supplied: nil,
              buildargs_collected: nil,
              msg_receiver: nil,
              current_step: nil,
              instructions: nil,
              processed_instructions: nil,
              snapshots: nil,
              total_steps: nil,
              container: nil,
              workdir: nil,
              cleanup: true,
              quiet: false
  end

  @type t() :: %Schemas.Image{}

  @spec build(String.t(), String.t(), String.t(), String.t(), boolean(), boolean()) ::
          {:ok, pid()} | {:error, String.t()}
  def build(context_path, dockerfile, tag, buildargs, cleanup, quiet \\ false) do
    {name, tag} = Kleened.Core.Utils.decode_tagname(tag)
    dockerfile_path = Path.join(context_path, dockerfile)

    case File.read(dockerfile_path) do
      {:ok, dockerfile} ->
        instructions = Kleened.Core.Dockerfile.parse(dockerfile)

        case verify_instructions(instructions) do
          :ok ->
            image_id = Kleened.Core.Utils.uuid()

            {:ok, buildnet} =
              Network.create(%Schemas.NetworkConfig{
                name: "buildnet_" <> image_id,
                subnet: "172.18.0.0/24",
                ifname: "kl" <> String.slice(image_id, 0..4),
                driver: "loopback"
              })

            state = %State{
              context: context_path,
              image_id: image_id,
              image_name: name,
              image_tag: tag,
              network: buildnet.id,
              buildargs_supplied: buildargs,
              buildargs_collected: [],
              msg_receiver: self(),
              current_step: 1,
              instructions: instructions,
              processed_instructions: [],
              snapshots: [],
              total_steps: length(instructions),
              container: %Schemas.Container{env: []},
              workdir: "/",
              cleanup: cleanup,
              quiet: quiet
            }

            pid = Process.spawn(fn -> process_instructions(state) end, [:link])
            {:ok, image_id, pid}

          {:error, error_msg} ->
            {:error, error_msg}
        end

      {:error, reason} ->
        msg = "Could not open Docker file #{dockerfile_path}: #{inspect(reason)}"
        {:error, msg}
    end
  end

  @spec tag(String.t(), String.t()) :: {:ok, %Schemas.Image{}} | {:error, String.t()}
  def tag(image_ident, nametag) do
    case MetaData.get_image(image_ident) do
      :not_found ->
        {:error, "image not found"}

      image ->
        {name, tag} = Utils.decode_tagname(nametag)
        image_updated = %Schemas.Image{image | name: name, tag: tag}
        MetaData.add_image(image_updated)
        {:ok, image_updated}
    end
  end

  @spec inspect_(String.t()) :: {:ok, %Schemas.Image{}} | {:error, String.t()}
  def inspect_(idname) do
    case MetaData.get_image(idname) do
      :not_found ->
        {:error, "image not found"}

      image ->
        {:ok, image}
    end
  end

  @spec remove(String.t()) :: :ok | :not_found
  def remove(id_or_nametag) do
    case MetaData.get_image(id_or_nametag) do
      :not_found ->
        :not_found

      %Schemas.Image{id: id, dataset: dataset} ->
        {_, 0} = ZFS.destroy_force(dataset)
        MetaData.delete_image(id)
    end
  end

  @spec prune(String.t()) :: {:ok, [String.t()]}
  def prune(all \\ false) do
    images = MetaData.list_image_datasets()
    prune_images(all, images, [])
  end

  defp prune_images(all, images, pruned_images) do
    dataset2clones = create_dataset2clones()

    case trim_images(images, dataset2clones, all, [], []) do
      {:ok, [], _remaining} ->
        # No images have been removed by trimming so we are done
        {:ok, List.flatten(pruned_images)}

      {:ok, deleted_images, remaining_images} ->
        # Images have been removed by trimming which might make new images eligible for removal
        # - if their children have been removed in a previous trim
        prune_images(all, remaining_images, [deleted_images | pruned_images])
    end
  end

  defp trim_images(
         [[id: image_id, name: name, tag: tag, dataset: dataset] = image | rest],
         dataset2clones,
         all,
         deleted,
         remaining
       ) do
    clones = Map.get(dataset2clones, dataset)

    case {all, name, tag, clones} do
      {true, _name, _tag, []} ->
        remove(image_id)
        trim_images(rest, dataset2clones, all, [image_id | deleted], remaining)

      {false, "", "", []} ->
        remove(image_id)
        trim_images(rest, dataset2clones, all, [image_id | deleted], remaining)

      _ ->
        trim_images(rest, dataset2clones, all, deleted, [image | remaining])
    end
  end

  defp trim_images([], _dataset2clones, _all, deleted, remaining) do
    {:ok, deleted, remaining}
  end

  defp create_dataset2clones() do
    kleened_root = Config.get("zroot")
    {output, 0} = OS.cmd(~w"/sbin/zfs list -H -t snapshot -o name,clones -r #{kleened_root}")
    processed_output = output |> String.split("\n") |> Enum.map(&String.split(&1, "\t"))
    Enum.reduce(processed_output, %{}, &create_dataset2clones_/2)
  end

  def create_dataset2clones_([""], dataset2clones) do
    dataset2clones
  end

  def create_dataset2clones_([snapshot, clones_raw], dataset2clones) do
    [dataset, _snapshot_name] = String.split(snapshot, "@")

    clones =
      case clones_raw do
        "-" -> []
        clones_nonempty -> String.split(clones_nonempty, ",")
      end

    Map.put(dataset2clones, dataset, clones)
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

  defp process_instructions(%State{instructions: [{line, {:from, image_ref}} | _]} = state) do
    Logger.info("Processing instruction: FROM #{image_ref}")
    state = send_status(line, state)

    with {:ok, new_image_ref} <- environment_replacement(image_ref, state),
         %Schemas.Image{id: image_id} <- Kleened.Core.MetaData.get_image(new_image_ref) do
      {:ok, container_config} =
        OpenApiSpex.Cast.cast(
          Schemas.ContainerConfig.schema(),
          %{
            name: "builder_" <> state.image_id,
            jail_param: ["mount.devfs=true"],
            image: image_id,
            user: "root",
            cmd: [],
            env: []
          }
        )

      {:ok, container} = Kleened.Core.Container.create(state.image_id, container_config)
      Network.connect(state.network, %Schemas.EndPointConfig{container: container.id})
      new_state = update_state(%State{state | container: container})
      process_instructions(new_state)
    else
      :not_found ->
        send_msg(state.msg_receiver, "parent image not found")
        terminate_failed_build(state)

      _ ->
        terminate_failed_build(state)
    end
  end

  defp process_instructions(
         %State{instructions: [{line, {:env, env_vars}} | _], container: container} = state
       ) do
    Logger.info("Processing instruction: ENV #{inspect(env_vars)}")
    state = send_status(line, state)

    case environment_replacement(env_vars, state) do
      {:ok, new_env_vars} ->
        env = Utils.merge_environment_variable_lists(container.env, [new_env_vars])

        process_instructions(
          update_state(%State{state | container: %Schemas.Container{container | env: env}})
        )

      :error ->
        terminate_failed_build(state)
    end
  end

  defp process_instructions(
         %State{instructions: [{line, {:arg, buildarg}} | _], buildargs_collected: buildargs} =
           state
       ) do
    Logger.info("Processing instruction: ARG #{buildarg}")
    state = send_status(line, state)
    buildargs = Utils.envlist2map(buildargs)
    buildarg = Utils.envlist2map([buildarg])
    buildargs = Map.merge(buildargs, buildarg)

    process_instructions(
      update_state(%State{state | buildargs_collected: Utils.map2envlist(buildargs)})
    )
  end

  defp process_instructions(%State{instructions: [{line, {:user, user}} | _]} = state) do
    Logger.info("Processing instruction: USER #{user}")
    state = send_status(line, state)

    case environment_replacement(user, state) do
      {:ok, new_user} ->
        process_instructions(
          update_state(%State{
            state
            | container: %Schemas.Container{state.container | user: new_user}
          })
        )

      :error ->
        terminate_failed_build(state)
    end
  end

  defp process_instructions(%State{instructions: [{line, {:workdir, workdir}} | _]} = state) do
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
      :ok ->
        process_instructions(update_state(%State{state | workdir: new_workdir}))

      :error ->
        terminate_failed_build(state)
    end
  end

  defp process_instructions(
         %State{instructions: [{line, {:cmd, cmd}} | _], container: container} = state
       ) do
    Logger.info("Processing instruction: CMD #{inspect(cmd)}")
    state = send_status(line, state)
    cmd = adapt_run_command_to_workdir(cmd, state.workdir)
    new_container = %Schemas.Container{container | cmd: cmd}
    process_instructions(update_state(%State{state | container: new_container}))
  end

  defp process_instructions(
         %State{instructions: [{line, {:run, cmd}} | _], container: container} = state
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
      :ok ->
        snapshot = snapshot_image(state.container, state.msg_receiver)
        process_instructions(update_state(state, snapshot))

      :error ->
        terminate_failed_build(state)
    end
  end

  defp process_instructions(%State{instructions: [{line, {:copy, src_dest}} | _]} = state) do
    Logger.info("Processing instruction: COPY #{inspect(src_dest)}")
    state = send_status(line, state)

    with {:ok, src_and_dest} <- environment_replacement_list(src_dest, [], state),
         {config_mkdir, config_cp} = copy_instruction_exec_configs(src_and_dest, state),
         {:ok, mountpoint} <- mount_context(state),
         :ok <- succesfully_run_execution(config_mkdir, state),
         :ok <- succesfully_run_execution(config_cp, state),
         :ok <- Mount.unmount(mountpoint) do
      snapshot = snapshot_image(state.container, state.msg_receiver)
      process_instructions(update_state(state, snapshot))
    else
      _error ->
        terminate_failed_build(state)
    end
  end

  defp process_instructions(%State{instructions: []} = state) do
    # No more instructions
    image = assemble_and_save_image(state)
    send_msg(state.msg_receiver, {:image_build_succesfully, image})
  end

  defp update_state(
         %State{
           instructions: [{line, _} | rest],
           processed_instructions: processed_instructions,
           snapshots: snapshots
         } = state,
         snapshot \\ ""
       ) do
    %State{
      state
      | instructions: rest,
        processed_instructions: [line | processed_instructions],
        snapshots: [snapshot | snapshots]
    }
  end

  defp terminate_failed_build(%State{container: %Schemas.Container{id: nil}} = state) do
    Network.remove(state.network)
    send_msg(state.msg_receiver, {:image_build_failed, "image build failed"})
  end

  defp terminate_failed_build(%State{cleanup: true} = state) do
    Container.remove(state.container.id)
    Network.remove(state.network)
    send_msg(state.msg_receiver, {:image_build_failed, "image build failed"})
  end

  defp terminate_failed_build(%State{cleanup: false} = state) do
    # When the build process terminates abruptly the state is not being updated, so do it now.
    %Schemas.Image{instructions: instructions} = assemble_and_save_image(update_state(state))

    [_instruction, snapshot] =
      instructions |> Enum.filter(fn [_, snapshot] -> snapshot != "" end) |> List.last()

    send_msg(state.msg_receiver, {:image_build_failed, {"image build failed", snapshot}})
  end

  defp assemble_and_save_image(%State{
         network: network,
         image_name: image_name,
         image_tag: image_tag,
         processed_instructions: instructions,
         snapshots: snapshots,
         container: %Schemas.Container{
           id: container_id,
           dataset: container_dataset,
           user: user,
           env: env,
           cmd: cmd
         }
       }) do
    Network.disconnect(container_id, network)
    {:ok, _network_id} = Network.remove(network)
    :ok = container_to_image(container_dataset, container_id)
    MetaData.delete_container(container_id)

    image = %Schemas.Image{
      id: container_id,
      user: user,
      name: image_name,
      tag: image_tag,
      cmd: cmd,
      env: env,
      instructions:
        Enum.zip(Enum.reverse(instructions), Enum.reverse(snapshots))
        |> Enum.map(fn {a, b} -> [a, b] end),
      created: DateTime.to_iso8601(DateTime.utc_now()),
      dataset: Const.image_dataset(container_id)
    }

    Kleened.Core.MetaData.add_image(image)
    image
  end

  defp container_to_image(container_dataset, image_id) do
    image_dataset = Const.image_dataset(image_id)
    {_, 0} = Kleened.Core.ZFS.rename(container_dataset, image_dataset)

    image_snapshot = image_dataset <> Const.image_snapshot()
    {_, 0} = Kleened.Core.ZFS.snapshot(image_snapshot)

    :ok
  end

  defp snapshot_image(%Schemas.Container{dataset: dataset}, pid) do
    snapshot = "@#{Utils.uuid()}"
    ZFS.snapshot(dataset <> snapshot)
    msg = Const.image_builder_snapshot_message(snapshot)
    send_msg(pid, msg)
    snapshot
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
      {cmd, "/"} ->
        cmd

      {["/bin/sh", "-c", cmd], workdir} ->
        ["/bin/sh", "-c", "cd #{workdir} && #{cmd}"]

      {cmd, _} ->
        cmd
    end
  end

  defp copy_instruction_exec_configs(src_and_dest, state) do
    src_and_dest = wildcard_expand_srcs(src_and_dest, state)
    src_and_dest = convert_paths_to_jail_context_dir_and_workdir(src_and_dest, state.workdir)

    # Create <dest> directory if it does not exist
    dest = Path.dirname(List.last(src_and_dest))

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

    dest =
      case String.last(dest) do
        "/" -> Path.join(workdir, dest) <> "/"
        _ -> Path.join(workdir, dest)
      end

    absolute_sources =
      Enum.map(relative_sources, fn src -> Path.join("/kleene_temporary_context_store", src) end)

    Enum.reverse([dest | absolute_sources])
  end

  defp mount_context(%State{msg_receiver: pid} = state) do
    mount_config = %Schemas.MountPointConfig{
      type: "nullfs",
      source: state.context,
      destination: "/kleene_temporary_context_store"
    }

    case Mount.create(state.container, mount_config) do
      {:ok, mountpoint} ->
        {:ok, mountpoint}

      {:error, output} ->
        send_msg(pid, "could not create context mountpoint in container: #{output}")
        :error
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
    msg = Const.image_builder_status_message(step, nsteps, line)
    send_msg(pid, msg)
    %State{state | :current_step => step + 1}
  end

  defp send_msg(pid, msg) do
    full_msg = {:image_builder, self(), msg}
    :ok = Process.send(pid, full_msg, [])
  end
end
