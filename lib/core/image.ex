defmodule Kleened.Core.Image do
  alias Kleened.Core.{Const, ZFS, MetaData, Utils, Mount, Network, OS, Container, Config}
  alias Kleened.API.Schemas
  require Logger

  defmodule State do
    defstruct image_id: nil,
              build_config: nil,
              buildargs_collected: nil,
              msg_receiver: nil,
              current_step: nil,
              instructions: nil,
              processed_instructions: nil,
              snapshots: nil,
              total_steps: nil,
              container: nil,
              workdir: nil
  end

  @type t() :: %Schemas.Image{}

  @spec build(%Schemas.ImageBuildConfig{}) :: {:ok, pid()} | {:error, String.t()}
  def build(
        %Schemas.ImageBuildConfig{
          context: context,
          dockerfile: dockerfile,
          tag: tag
        } = build_config
      ) do
    {_name, _tag} = Kleened.Core.Utils.decode_tagname(tag)
    dockerfile_path = Path.join(context, dockerfile)

    case File.read(dockerfile_path) do
      {:ok, dockerfile} ->
        case Kleened.Core.Dockerfile.parse(dockerfile) do
          {:ok, instructions} ->
            case starts_with_from_instruction(instructions) do
              :ok ->
                image_id = Kleened.Core.Utils.uuid()

                build_config = %Schemas.ImageBuildConfig{
                  build_config
                  | container_config: %Schemas.ContainerConfig{
                      build_config.container_config
                      | name: "builder_#{image_id}"
                    }
                }

                state = %State{
                  build_config: build_config,
                  image_id: image_id,
                  buildargs_collected: [],
                  msg_receiver: self(),
                  current_step: 1,
                  instructions: instructions,
                  processed_instructions: [],
                  snapshots: [],
                  total_steps: length(instructions),
                  container: %Schemas.Container{env: []},
                  workdir: "/"
                }

                pid = Process.spawn(fn -> process_instructions(state) end, [:link])
                {:ok, image_id, pid}

              {:error, error_msg} ->
                {:error, error_msg}
            end

          {:error, error_msg} ->
            {:error, error_msg}
        end

      {:error, reason} ->
        msg = "Could not open Docker file #{dockerfile_path}: #{inspect(reason)}"
        {:error, msg}
    end
  end

  defp starts_with_from_instruction([instruction | rest]) do
    case instruction do
      {_line, {:arg, _}} ->
        starts_with_from_instruction(rest)

      {_line, {:from, _}} ->
        :ok

      {_line, {:from, _, _}} ->
        :ok

      {line, _illegal_instruction} ->
        reason = "'#{line}' not permitted before a FROM instruction"
        {:error, reason}
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

  @spec remove(String.t()) :: :ok | {:error, String.t()}
  def remove(id_or_nametag) do
    case MetaData.get_image(id_or_nametag) do
      :not_found ->
        {:error, "Error: No such image: #{id_or_nametag}\n"}

      %Schemas.Image{} = image ->
        case zfs_kleene_clones(image.dataset) do
          :no_clones ->
            case ZFS.cmd("destroy -r -v #{image.dataset}") do
              {_, 0} ->
                MetaData.delete_image(image.id)
                :ok

              {output, 1} ->
                MetaData.delete_image(image.id)
                {:error, "deleted image but could not remove image dataset: #{output}"}
            end

          {:container_clones, container_ids} ->
            msg = "could not remove image #{image.id} since it is used for containers:"
            clone_error_message(msg, container_ids)

          {:image_clones, image_ids} ->
            msg = "could not remove image #{image.id} since it is used for images:"
            clone_error_message(msg, image_ids)
        end
    end
  end

  defp clone_error_message(msg, id_list) do
    msg = [msg | id_list] |> Enum.join("\n")
    {:error, msg}
  end

  defp zfs_kleene_clones(dataset) do
    with {output, 1} <- ZFS.cmd("destroy -n -r -p #{dataset}"),
         true <- String.contains?(output, "filesystem has dependent clones"),
         [_, _ | datasets] = String.split(output, "\n"),
         {:container_clones, []} <- zfs_container_clones(datasets),
         {:image_clones, []} <- zfs_image_clones(datasets) do
      :no_clones
    else
      {_, 0} -> :no_clones
      false -> :no_clones
      {:container_clones, _container_ids} = clones -> clones
      {:image_clones, _image_ids} = clones -> clones
    end
  end

  defp zfs_container_clones(datasets) do
    container_root = Config.get("container_root") <> "/"
    container_ids = extract_clones(container_root, datasets)
    {:container_clones, container_ids}
  end

  defp zfs_image_clones(datasets) do
    image_root = Config.get("image_root") <> "/"
    image_datasets_and_clones = extract_clones(image_root, datasets)
    # Remove @image snapshot lines - otherwise there are duplicates
    image_ids =
      Enum.filter(image_datasets_and_clones, fn dataset ->
        case String.split(dataset, "@") do
          [_] -> true
          [_, _] -> false
        end
      end)

    {:image_clones, image_ids}
  end

  defp extract_clones(root, datasets) do
    datasets
    |> Enum.filter(&String.starts_with?(&1, root))
    |> Enum.map(fn dataset ->
      ["", object_id] = String.split(dataset, root)
      object_id
    end)
  end

  @spec prune(false | true) :: {:ok, [String.t()]}
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
         [%{id: image_id, name: name, tag: tag, dataset: dataset} = image | rest],
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
    kleened_root = Config.get("kleene_root")
    {output, 0} = OS.cmd(~w"/sbin/zfs list -H -t snapshot -o name,clones -r #{kleened_root}")
    processed_output = output |> String.split("\n") |> Enum.map(&String.split(&1, "\t"))
    Enum.reduce(processed_output, %{}, &create_dataset2clones_/2)
  end

  def create_dataset2clones_([""], dataset2clones) do
    dataset2clones
  end

  def create_dataset2clones_([snapshot, clones_raw], dataset2clones) do
    [dataset, _snapshot_name] = String.split(snapshot, "@")

    union_clones =
      case {Map.get(dataset2clones, dataset), clones_raw} do
        {nil, "-"} ->
          []

        {old_clones, "-"} ->
          old_clones

        {old_clones, new_clones_csv} ->
          String.split(new_clones_csv, ",") ++ old_clones
      end

    Map.put(dataset2clones, dataset, union_clones)
  end

  defp validate_image_reference(image_ident) do
    case Utils.decode_snapshot(image_ident) do
      {_nametag, ""} ->
        case Kleened.Core.MetaData.get_image(image_ident) do
          %Kleened.API.Schemas.Image{} = image -> {:ok, image}
          :not_found -> {:error, "could not find image #{image_ident}"}
        end

      {nametag, snapshot} ->
        case Kleened.Core.MetaData.get_image(nametag) do
          :not_found ->
            {:error, "could not find image #{nametag}"}

          %Kleened.API.Schemas.Image{} = image ->
            case OS.shell(
                   "/sbin/zfs list -t snapshot -o name -H #{image.dataset} | grep #{snapshot}"
                 ) do
              {_, 0} ->
                {:ok, image}

              {_, _non_zero_exitcode} ->
                {:error, "invalid snapshot #{snapshot}"}
            end
        end
    end
  end

  defp process_instructions(%State{instructions: [{line, {:from, image_ref}} | _]} = state) do
    Logger.info("Processing instruction: FROM #{image_ref}")
    state = send_status(line, state)

    with {:ok, image_ident} <- determine_parent_image(image_ref, state),
         {:ok, image} <- validate_image_reference(image_ident),
         {:ok, container} <-
           Kleened.Core.Container.create(state.image_id, %Schemas.ContainerConfig{
             state.build_config.container_config
             | image: image_ident,
               cmd: image.cmd
           }),
         :ok <- create_build_container_connectivity(container, state.build_config.networks) do
      new_state = update_state(%State{state | container: container})
      process_instructions(new_state)
    else
      :not_found ->
        send_msg(state.msg_receiver, "error: parent image not found")
        terminate_failed_build(state)

      {:error, reason} ->
        send_msg(state.msg_receiver, "error: #{reason}")
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
      user: container.user,
      tty: true
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
         :ok <- succesfully_run_execution(config_mkdir, state),
         {:ok, mountpoint} <- create_context_nullfs_mount(state),
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
    send_msg(state.msg_receiver, {:image_build_failed, "image build failed"})
  end

  defp terminate_failed_build(
         %State{build_config: %Schemas.ImageBuildConfig{cleanup: true}} = state
       ) do
    Container.stop(state.container.id)
    Container.remove(state.container.id)
    send_msg(state.msg_receiver, {:image_build_failed, "image build failed"})
  end

  defp terminate_failed_build(
         %State{build_config: build_config = %Schemas.ImageBuildConfig{cleanup: false}} = state
       ) do
    # When the build process terminates abruptly the state is not being updated, so do it now.
    Container.stop(state.container.id)
    {image_name, _image_tag} = Kleened.Core.Utils.decode_tagname(state.build_config.tag)
    build_config = %Schemas.ImageBuildConfig{build_config | tag: "#{image_name}:failed"}
    state = %State{state | build_config: build_config}

    %Schemas.Image{instructions: instructions} = assemble_and_save_image(update_state(state))

    snapshots = instructions |> Enum.filter(fn [_, snapshot] -> snapshot != "" end)

    case snapshots do
      [] ->
        send_msg(
          state.msg_receiver,
          {:image_build_failed, {"image build failed", "no snapshots available"}}
        )

      snapshots ->
        [_instruction, snapshot] = List.last(snapshots)
        send_msg(state.msg_receiver, {:image_build_failed, {"image build failed", snapshot}})
    end
  end

  defp assemble_and_save_image(%State{
         processed_instructions: instructions,
         snapshots: snapshots,
         build_config: %Schemas.ImageBuildConfig{
           tag: nametag
         },
         container: %Schemas.Container{
           id: container_id,
           dataset: container_dataset,
           user: user,
           env: env,
           cmd: cmd
         }
       }) do
    {image_name, image_tag} = Kleened.Core.Utils.decode_tagname(nametag)
    Container.stop(container_id)
    Network.disconnect_all(container_id)
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
           buildargs_collected: buildargs_collected,
           build_config: %Schemas.ImageBuildConfig{buildargs: buildargs},
           container: %Schemas.Container{env: env}
         }
       ) do
    args = merge_buildargs(buildargs, buildargs_collected)
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
         buildargs_collected: buildargs_collected,
         build_config: %Schemas.ImageBuildConfig{buildargs: buildargs},
         container: %Schemas.Container{env: env}
       }) do
    args = merge_buildargs(buildargs, buildargs_collected)
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

      {:container, ^exec_id, {:shutdown, {:jailed_process_exited, exit_code}}} ->
        exit_code

      {:container, ^exec_id, msg} ->
        if not state.build_config.quiet do
          send_msg(state.msg_receiver, msg)
        end

        relay_output_and_await_shutdown(id, exec_id, state)

      {:container, ^exec_id, {:jail_output, msg}} ->
        if not state.build_config.quiet do
          send_msg(state.msg_receiver, {:jail_output, msg})
        end

        relay_output_and_await_shutdown(id, exec_id, state)

      other ->
        Logger.error("Weird stuff received: #{inspect(other)}")
    end
  end

  defp determine_parent_image(image_from_dockerfile, state) do
    case state.build_config.container_config.image do
      nil ->
        environment_replacement(image_from_dockerfile, state)

      user_supplied_image ->
        msg = "Using user-supplied parent image: '#{user_supplied_image}'"
        send_msg(state.msg_receiver, {:jail_output, msg})
        {:ok, user_supplied_image}
    end
  end

  defp create_build_container_connectivity(container, [endpoint_config | rest]) do
    config = %Schemas.EndPointConfig{endpoint_config | container: container.id}

    case Network.connect(config) do
      {:ok, _endpoint} -> create_build_container_connectivity(container, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_build_container_connectivity(_container, []) do
    :ok
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
    context_depth = length(Path.split(state.build_config.context))

    expanded_sources =
      Enum.flat_map(srcs_relative, fn src_rel ->
        # Wildcard-expand on the hosts absolute paths
        src_expanded_list = Path.join(state.build_config.context, src_rel) |> Path.wildcard()

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

  defp create_context_nullfs_mount(%State{msg_receiver: pid} = state) do
    mount_config = %Schemas.MountPointConfig{
      type: "nullfs",
      source: state.build_config.context,
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

  defp send_status(_line, %State{build_config: %Schemas.ImageBuildConfig{quiet: true}} = state) do
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
