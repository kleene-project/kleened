defmodule Kleened.Core.Container do
  defmodule State do
    defstruct container_id: nil,
              subscribers: nil,
              starting_port: nil
  end

  alias __MODULE__, as: Container

  require Logger
  alias Kleened.Core.{Config, Const, MetaData, Mount, Network, Utils, OS}
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

  @spec create(String.t(), container_config) ::
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
      %Schemas.Container{id: container_id} ->
        stop_container(container_id)

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

    with {:image, %Schemas.Image{} = image} <- {:image, MetaData.get_image(image_name)},
         :ok <- valid_port_publishing_container(config),
         {:ok, dataset} <- create_dataset(potential_image_snapshot, container_id, image) do
      assemble_container(container_id, image, dataset, config)
    else
      {:image, :not_found} ->
        {:error, "no such image '#{image_ident}'"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_port_publishing_container(%Schemas.ContainerConfig{
         public_ports: []
       }) do
    :ok
  end

  defp valid_port_publishing_container(%Schemas.ContainerConfig{
         network_driver: driver,
         public_ports: public_ports
       }) do
    case driver do
      "host" ->
        {:error, "cannot publish ports of a container with a 'host' network driver"}

      "disabled" ->
        {:error, "cannot publish ports of a container with a 'disabled' network driver"}

      _ ->
        Network.validate_pubport_set(public_ports)
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

    dataset = Path.join([Config.get("zroot"), "container", container_id])

    case Kleened.Core.ZFS.clone(parent_snapshot, dataset) do
      {_, 0} -> {:ok, dataset}
      {reason, _nonzero_exit} -> {:error, reason}
    end
  end

  defp prune_containers() do
    pruned_containers =
      Enum.reduce(list(all: true), [], fn
        %{running: false, id: container_id}, removed_containers ->
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
           jail_param: jail_param
         }
       ) do
    case MetaData.get_container(container_id) do
      %Schemas.Container{} = container ->
        case update_container_object(container,
               name: name,
               user: user,
               env: env,
               cmd: cmd,
               jail_param: jail_param
             ) do
          {:ok, container} -> modify_container_if_running(container, jail_param)
          {:warning, msg} -> {:warning, msg}
        end

      :not_found ->
        {:error, :container_not_found}
    end
  end

  defp update_container_object(container, simple_vars) do
    container_upd = Enum.reduce(simple_vars, container, &update_container_property/2)

    if container != container_upd do
      Logger.debug("updated container #{container.id}")
      MetaData.add_container(container_upd)
    end

    {:ok, container_upd}
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
             "'/usr/sbin/jail' returned non-zero exitcode #{nonzero_exit} when attempting to modify the container '#{
               output
             }'"}
        end

      false ->
        {:ok, container}
    end
  end

  defp assemble_container(
         container_id,
         %Schemas.Image{
           id: image_id,
           user: image_user,
           cmd: image_command,
           env: img_env
         },
         dataset,
         %Schemas.ContainerConfig{
           name: name,
           user: user,
           env: env,
           mounts: mounts,
           cmd: command,
           jail_param: jail_param,
           network_driver: network_driver,
           public_ports: pub_port_configs
         } = config
       ) do
    Logger.debug("creating container on #{dataset} with config: #{inspect(config)}")

    env = Utils.merge_environment_variable_lists(img_env, env)

    host_gw =
      case Network.host_gateway_interface() do
        {:ok, host_gw} ->
          host_gw

        {:error, _reason} ->
          Logger.warn(
            "Could not detect any gateway interface on the host so connectivity might not work."
          )

          ""
      end

    pub_ports =
      pub_port_configs
      |> Enum.map(fn %Schemas.PublicPortConfig{
                       interfaces: interfaces,
                       host_port: host_port,
                       container_port: container_port,
                       protocol: protocol
                     } ->
        interfaces =
          case {interfaces, host_gw} do
            {[], ""} -> []
            {[], host_gw} -> [host_gw]
            _ -> interfaces
          end

        %Schemas.PublicPort{
          interfaces: interfaces,
          host_port: host_port,
          container_port: container_port,
          protocol: protocol,
          ip_address: "",
          ip_address6: ""
        }
      end)

    command =
      case command do
        [] -> image_command
        _ -> command
      end

    user =
      case user do
        "" -> image_user
        _ -> user
      end

    container = %Schemas.Container{
      id: container_id,
      name: name,
      cmd: command,
      dataset: dataset,
      image_id: image_id,
      user: user,
      jail_param: jail_param,
      network_driver: network_driver,
      public_ports: pub_ports,
      env: env,
      created: DateTime.to_iso8601(DateTime.utc_now()),
      running: false
    }

    case Network.validate_pubport_set(pub_ports) do
      :ok ->
        case create_mounts(container, mounts) do
          :ok ->
            MetaData.add_container(container)
            {:ok, container}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_(:not_found), do: {:error, :not_found}

  defp remove_(%Schemas.Container{id: container_id, dataset: dataset} = cont) do
    case Utils.is_container_running?(container_id) do
      false ->
        :ok = Network.disconnect_all(container_id)
        :ok = Mount.remove_mounts(cont)
        :ok = MetaData.delete_container(container_id)
        {_, 0} = Kleened.Core.ZFS.destroy_force(dataset)
        {:ok, container_id}

      true ->
        {:error, :is_running}
    end
  end

  @spec stop_container(%State{}) :: {:ok, String.t()} | {:error, String.t()}
  def stop_container(container_id) do
    case Utils.is_container_running?(container_id) do
      true ->
        Logger.debug("Shutting down jail #{container_id}")

        {output, exit_code} =
          System.cmd("/usr/sbin/jail", ["-r", container_id], stderr_to_stdout: true)

        case {output, exit_code} do
          {output, 0} ->
            Logger.info("Stopped jail #{container_id} with exit code #{exit_code}: #{output}")
            {:ok, container_id}

          {output, _} ->
            Logger.warn("Stopped jail #{container_id} with exit code #{exit_code}: #{output}")
            msg = "/usr/sbin/jail exited abnormally with exit code #{exit_code}: '#{output}'"
            {:error, msg}
        end

      false ->
        {:error, "container not running"}
    end
  end

  @spec list_([list_containers_opts()]) :: [%{}]
  defp list_(options) do
    active_jails = MapSet.new(running_jails())

    containers =
      Enum.map(
        MetaData.container_listing(),
        &Map.put(&1, :running, MapSet.member?(active_jails, &1[:id]))
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
      {:ok, _} -> create_mounts(container, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_mounts(_container, []) do
    :ok
  end

  def running_jails() do
    {jails_json, 0} = System.cmd("jls", ["-v", "--libxo=json"], stderr_to_stdout: true)
    {:ok, jails} = Jason.decode(jails_json)
    jails = Enum.map(jails["jail-information"]["jail"], & &1["name"])
    jails
  end
end
