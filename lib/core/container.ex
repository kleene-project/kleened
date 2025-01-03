defmodule Kleened.Core.Container do
  defmodule State do
    defstruct container_id: nil,
              subscribers: nil,
              starting_port: nil
  end

  alias __MODULE__, as: Container

  require Logger
  alias Kleened.Core.{Config, Const, MetaData, Mount, Network, Utils, OS, FreeBSD, ZFS}
  alias Kleened.API.Schemas

  @type t() :: %Schemas.Container{}

  @type container_config() :: %Schemas.ContainerConfig{}

  @type list_containers_opts :: [
          {:all, boolean()}
        ]

  @type container_id() :: String.t()

  @type id_or_name() :: container_id() | String.t()

  ### ===================================================================
  ### API
  ### ===================================================================
  @spec create(container_config) :: {:ok, Container.t()} | {:error, String.t()}
  def create(options) do
    container_id = Kleened.Core.Utils.uuid()
    create_(container_id, options)
  end

  @spec create(container_id(), container_config) ::
          {:ok, Container.t()} | {:error, String.t()}
  def create(container_id, options) do
    create_(container_id, options)
  end

  @spec remove(id_or_name()) ::
          {:ok, container_id()} | {:error, :not_found} | {:error, :is_running}
  def remove(id_or_name) do
    cont = MetaData.get_container(id_or_name)
    remove_(cont)
  end

  @spec prune() :: {:ok, [container_id()]}
  def prune() do
    prune_containers()
  end

  @spec update(String.t(), container_config) ::
          :ok | {:warning, String.t()} | {:error, String.t()}
  def update(container_id, config) do
    update_(container_id, config)
  end

  @spec stop(id_or_name()) :: {:ok, String.t()} | {:error, String.t()}
  def stop(id_or_name) do
    case MetaData.get_container(id_or_name) do
      %Schemas.Container{} = container ->
        stop_container(container)

      :not_found ->
        {:error, "container not found"}
    end
  end

  @spec inspect_(String.t()) :: {:ok, %Schemas.ContainerInspect{}} | {:error, String.t()}
  def inspect_(idname) do
    case MetaData.get_container(idname) do
      :not_found ->
        {:error, "container not found"}

      container ->
        running = Utils.is_container_running?(container.id)
        container = %Schemas.Container{container | running: running}
        endpoints = MetaData.get_endpoints_from_container(container.id)
        mountpoints = MetaData.list_mounts_by_container(container.id)

        {:ok,
         %Schemas.ContainerInspect{
           container: container,
           container_endpoints: endpoints,
           container_mountpoints: mountpoints
         }}
    end
  end

  @spec list([list_containers_opts()]) :: [%{}]
  def list(options \\ []) do
    list_(options)
  end

  ### ===================================================================
  ### Internal functions
  ### ===================================================================
  defp create_(
         container_id,
         %Schemas.ContainerConfig{image: image_ident} = config
       ) do
    {image_name, potential_image_snapshot} = Utils.decode_snapshot(image_ident)

    with :ok <- validate_name(config.name),
         {:image, %Schemas.Image{} = image} <- {:image, MetaData.get_image(image_name)},
         {:ok, pub_ports} <- validate_public_ports(config),
         {:ok, dataset} <- create_dataset(potential_image_snapshot, container_id, image) do
      assemble_container(container_id, image, dataset, pub_ports, config)
    else
      {:image, :not_found} ->
        {:error, "no such image '#{image_ident}'"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_name(nil) do
    :ok
  end

  defp validate_name(name) do
    case name =~ ~r"^/?[a-zA-Z0-9][a-zA-Z0-9_.-]+$" do
      true -> :ok
      false -> {:error, "#{name} does not match /\?\[a-zA-Z0-9\]\[a-zA-Z0-9\_\.-\]\+\$"}
    end
  end

  defp validate_public_ports(%Schemas.ContainerConfig{
         public_ports: []
       }) do
    {:ok, []}
  end

  defp validate_public_ports(%Schemas.ContainerConfig{
         network_driver: driver
       })
       when driver == "host" or driver == "disabled" do
    {:error, "cannot publish ports of a container using the '#{driver}' network driver"}
  end

  defp validate_public_ports(%Schemas.ContainerConfig{
         public_ports: public_ports_config
       }) do
    host_gw =
      case Config.get("host_gateway") do
        nil ->
          Logger.warning("No host gateway detected. Connectivity might not work.")
          ""

        host_gateway ->
          host_gateway
      end

    public_ports =
      Enum.map(public_ports_config, fn %Schemas.PublishedPortConfig{
                                         interfaces: interfaces,
                                         host_port: host_port,
                                         container_port: container_port,
                                         protocol: protocol
                                       } ->
        interfaces =
          case {interfaces, host_gw} do
            {[], ""} -> []
            {[], _} -> [host_gw]
            _ -> interfaces
          end

        %Schemas.PublishedPort{
          interfaces: interfaces,
          host_port: host_port,
          container_port: container_port,
          protocol: protocol,
          ip_address: "",
          ip_address6: ""
        }
      end)

    case Network.validate_pubports(public_ports) do
      :ok -> {:ok, public_ports}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_dataset(potential_image_snapshot, container_id, image) do
    parent_snapshot =
      case potential_image_snapshot do
        "" ->
          snapshot = "#{image.dataset}#{Const.image_snapshot()}"
          Logger.info("Creating container from image #{snapshot}")
          snapshot

        snapshot ->
          snapshot = "#{image.dataset}#{snapshot}"
          Logger.info("Creating container from image snapshot #{snapshot}")
          snapshot
      end

    dataset = Path.join([Config.get("kleene_root"), "container", container_id])

    case Kleened.Core.ZFS.clone(parent_snapshot, dataset) do
      {_, 0} -> {:ok, dataset}
      {reason, _nonzero_exit} -> {:error, reason}
    end
  end

  defp prune_containers() do
    pruned_containers =
      Enum.reduce(list(all: true), [], fn
        %{running: false, persist: false, id: container_id}, removed_containers ->
          Logger.debug("pruning container #{container_id}")
          remove(container_id)
          [container_id | removed_containers]

        _, removed_containers ->
          removed_containers
      end)

    {:ok, pruned_containers}
  end

  defp update_(
         container_id,
         %Schemas.ContainerConfig{
           name: name,
           user: user,
           env: env,
           mounts: _mounts,
           cmd: cmd,
           persist: persist,
           restart_policy: restart,
           jail_param: jail_param
         }
       ) do
    case MetaData.get_container(container_id) do
      %Schemas.Container{} = container ->
        update_container_object(container,
          name: name,
          user: user,
          env: env,
          cmd: cmd,
          persist: persist,
          restart_policy: restart,
          jail_param: jail_param
        )

      :not_found ->
        {:error, :container_not_found}
    end
  end

  defp update_container_object(container, simple_vars) do
    container_upd = Enum.reduce(simple_vars, container, &update_container_property/2)

    if container != container_upd do
      result = modify_container_if_running(container_upd, container_upd.jail_param)

      if result == {:ok, container_upd} do
        Logger.debug("updated container #{container.id}")
        MetaData.add_container(container_upd)
      end

      result
    else
      {:ok, container}
    end
  end

  defp update_container_property({_var_name, nil}, container) do
    container
  end

  defp update_container_property({var_name, var_val}, container) do
    Map.put(container, var_name, var_val)
  end

  defp modify_container_if_running(container, jail_param) do
    case is_running?(container.id) do
      true ->
        command = ["/usr/sbin/jail", "-m", "name=#{container.id}" | jail_param]

        case OS.cmd(command, %{suppress_warning: false}) do
          {_output, 0} ->
            {:ok, container}

          {output, nonzero_exit} ->
            {:warning,
             "'/usr/sbin/jail' returned non-zero exitcode #{nonzero_exit} when attempting to modify the container '#{output}'"}
        end

      false ->
        {:ok, container}
    end
  end

  defp assemble_container(
         container_id,
         image,
         dataset,
         pub_ports,
         %Schemas.ContainerConfig{
           user: user,
           env: env,
           mounts: mounts,
           cmd: command
         } = config
       ) do
    Logger.debug("creating container on #{dataset} with config: #{inspect(config)}")

    env = Utils.merge_environment_variable_lists(image.env, env)
    container_map = Map.from_struct(config) |> Map.drop([:image, :mounts])

    command =
      case command do
        [] -> image.cmd
        _ -> command
      end

    user =
      case user do
        "" -> image.user
        _ -> user
      end

    container =
      struct(
        Schemas.Container,
        Map.merge(container_map, %{
          id: container_id,
          cmd: command,
          dataset: dataset,
          image_id: image.id,
          user: user,
          public_ports: pub_ports,
          env: env,
          created: DateTime.to_iso8601(DateTime.utc_now()),
          running: false
        })
      )

    case create_mounts(container, mounts) do
      :ok ->
        MetaData.add_container(container)
        {:ok, container}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_(:not_found), do: {:error, :not_found}

  defp remove_(%Schemas.Container{} = container) do
    case Utils.is_container_running?(container.id) do
      false ->
        :ok = Network.disconnect_all(container.id)
        :ok = Mount.remove_mounts(container)
        mountpoint = ZFS.mountpoint(container.dataset)
        FreeBSD.clear_devfs(mountpoint)
        :ok = MetaData.delete_container(container.id)
        {_, 0} = Kleened.Core.ZFS.destroy_force(container.dataset)
        {:ok, container.id}

      true ->
        {:error, :is_running}
    end
  end

  @spec stop_container(%Schemas.Container{}) :: {:ok, String.t()} | {:error, String.t()}
  defp stop_container(container) do
    case Utils.is_container_running?(container.id) do
      true ->
        Logger.debug("Shutting down container #{container.id}")

        {output, exit_code} =
          System.cmd("/usr/sbin/jail", ["-r", container.id], stderr_to_stdout: true)

        cleanup_container(container)

        case {output, exit_code} do
          {output, 0} ->
            Logger.info("Stopped jail #{container.id} with exit code #{exit_code}: #{output}")
            {:ok, container}

          {output, _} ->
            Logger.warning("Stopped jail #{container.id} with exit code #{exit_code}: #{output}")
            msg = "/usr/sbin/jail exited abnormally with exit code #{exit_code}: '#{output}'"
            {:error, msg}
        end

      false ->
        cleanup_container(container)
        {:error, "container not running"}
    end
  end

  def cleanup_container(container) do
    # Remove all system componenents that are not required when the container is stopped:
    # - 'ipnet': All ip-addresses of the container
    # - 'vnet': All epair interfaces of the container
    # - all nullfs/volume-mounts of the container
    # - 'devfs'-mount, if it exists
    case container.network_driver do
      "vnet" ->
        MetaData.connected_networks(container.id)
        |> Enum.map(fn network ->
          config = MetaData.get_endpoint(container.id, network.id)
          FreeBSD.destroy_bridged_epair(config.epair, network.interface)
          config = %Schemas.EndPoint{config | epair: nil}
          MetaData.add_endpoint(container.id, network.id, config)
        end)

      "ipnet" ->
        MetaData.connected_networks(container.id)
        |> Enum.map(fn network ->
          config = MetaData.get_endpoint(container.id, network.id)
          Network.ifconfig_alias_remove(config.ip_address, network.interface, "inet")
          Network.ifconfig_alias_remove(config.ip_address6, network.interface, "inet6")
        end)

      _ ->
        :ok
    end

    # Regarding devfs-mounts:
    # - If it was closed with 'jail -r <jailname>' devfs should be removed automatically.
    # - If the jail stops because there jailed process stops (i.e. 'jail -c <etc> /bin/sleep 10') then devfs is NOT removed.
    # A race condition can also occur such that "jail -r" does not unmount before this call to mount.
    mounts = MetaData.get_mounts_from_container(container.id)
    Enum.map(mounts, fn mountpoint -> Mount.unmount(mountpoint) end)
    mountpoint = ZFS.mountpoint(container.dataset)
    FreeBSD.clear_devfs(mountpoint)
  end

  @spec list_([list_containers_opts()]) :: [%{}]
  defp list_(options) do
    active_jails = Map.new(FreeBSD.running_jails())

    containers =
      Enum.map(
        MetaData.container_listing(),
        fn container ->
          case Map.has_key?(active_jails, container.id) do
            true ->
              container
              |> Map.put(:running, true)
              |> Map.put(:jid, active_jails[container.id])

            false ->
              container |> Map.put(:running, false) |> Map.put(:jid, nil)
          end
        end
      )

    case Keyword.get(options, :all, false) do
      true -> containers
      false -> Enum.filter(containers, & &1[:running])
    end
  end

  def is_running?(container_id) do
    output = System.cmd("jls", ["--libxo=json", "-j", container_id], stderr_to_stdout: true)

    case output do
      {_json, 1} -> false
      {_json, 0} -> true
    end
  end

  defp create_mounts(container, [mount_config | rest]) do
    case Mount.create(container, mount_config) do
      {:ok, _} ->
        create_mounts(container, rest)

      {:error, reason} ->
        Logger.warning("Could not mount #{inspect(mount_config)}: #{reason}")
        {:error, reason}
    end
  end

  defp create_mounts(_container, []) do
    :ok
  end
end
