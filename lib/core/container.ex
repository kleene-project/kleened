defmodule Kleened.Core.Container do
  defmodule State do
    defstruct container_id: nil,
              subscribers: nil,
              starting_port: nil
  end

  alias __MODULE__, as: Container

  require Logger
  alias Kleened.Core.{MetaData, Volume, Layer, Network, Utils}
  alias Kleened.API.Schemas

  @type t() ::
          %Schemas.Container{
            id: String.t(),
            name: String.t(),
            command: [String.t()],
            layer_id: String.t(),
            image_id: String.t(),
            user: String.t(),
            jail_param: [String.t()],
            env: [String.t()],
            created: String.t()
          }

  @type create_opts() :: %Schemas.ContainerConfig{}

  @type list_containers_opts :: [
          {:all, boolean()}
        ]

  @type container_id() :: String.t()

  @type id_or_name() :: container_id() | String.t()

  ### ===================================================================
  ### API
  ### ===================================================================
  @spec create(String.t(), create_opts) :: {:ok, Container.t()} | {:error, :image_not_found}
  def create(name, options) do
    container_id = Kleened.Core.Utils.uuid()
    create_(container_id, name, options)
  end

  @spec create(String.t(), String.t(), create_opts) ::
          {:ok, Container.t()} | {:error, :image_not_found}
  def create(container_id, name, options) do
    create_(container_id, name, options)
  end

  @spec remove(id_or_name()) :: {:ok, container_id()} | {:error, :not_found}
  def remove(id_or_name) do
    cont = MetaData.get_container(id_or_name)
    remove_(cont)
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
        endpoints = MetaData.get_endpoints_from_container(container.id)
        {:ok, %Schemas.ContainerInspect{container: container, container_endpoints: endpoints}}
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
         name,
         %Schemas.ContainerConfig{image: image_identifier} = config
       ) do
    {image_name, snapshot} = Utils.decode_snapshot(image_identifier)
    image = MetaData.get_image(image_name)

    case {image, snapshot} do
      {%Schemas.Image{layer_id: parent_layer_id} = image, ""} ->
        parent_layer = Kleened.Core.MetaData.get_layer(parent_layer_id)
        {:ok, layer} = Layer.new(parent_layer, container_id)
        assemble_container({name, container_id}, image, layer, config)

      {%Schemas.Image{layer_id: parent_layer_id} = image, snapshot} ->
        parent_layer = Kleened.Core.MetaData.get_layer(parent_layer_id)

        parent_layer_altered = %Layer{
          parent_layer
          | snapshot: "#{parent_layer.dataset}@#{snapshot}"
        }

        case Layer.new(parent_layer_altered, container_id) do
          {:ok, layer} ->
            assemble_container({name, container_id}, image, layer, config)

          {:error, reason} ->
            {:error, reason}
        end

      {:not_found, _} ->
        {:error, :image_not_found}
    end
  end

  defp assemble_container(
         {name, container_id},
         %Schemas.Image{
           id: image_id,
           user: image_user,
           command: image_command,
           env: img_env
         },
         %Layer{id: layer_id},
         %Schemas.ContainerConfig{
           user: user,
           env: env,
           volumes: volumes,
           cmd: command,
           jail_param: jail_param
         } = config
       ) do
    Logger.debug("creating container on layer #{layer_id} with config: #{inspect(config)}")

    env = Utils.merge_environment_variable_lists(img_env, env)

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

    cont = %Schemas.Container{
      id: container_id,
      name: name,
      command: command,
      layer_id: layer_id,
      image_id: image_id,
      user: user,
      jail_param: jail_param,
      env: env,
      created: DateTime.to_iso8601(DateTime.utc_now()),
      running: false
    }

    # Mount volumes into container (if any have been provided)
    bind_volumes(volumes, cont)

    # Store new container
    MetaData.add_container(cont)

    {:ok, MetaData.get_container(container_id)}
  end

  defp remove_(:not_found), do: {:error, :not_found}

  defp remove_(%Schemas.Container{id: container_id, layer_id: layer_id} = cont) do
    Network.disconnect_all(container_id)
    Volume.destroy_mounts(cont)
    MetaData.delete_container(container_id)
    Layer.destroy(layer_id)
    {:ok, container_id}
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
            Logger.info("Stopped jail #{container_id} with exitcode #{exit_code}: #{output}")
            {:ok, container_id}

          {output, _} ->
            Logger.warn("Stopped jail #{container_id} with exitcode #{exit_code}: #{output}")
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
        MetaData.list_containers(),
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

  defp bind_volumes(volumes, container) do
    Enum.map(volumes, fn vol -> bind_volumes_(vol, container) end)
  end

  defp bind_volumes_(volume_raw, cont) do
    case String.split(volume_raw, ":") do
      [<<"/", _::binary>> = location] ->
        # anonymous volume
        create_and_bind("", location, [ro: false], cont)

      [<<"/", _::binary>> = location, "ro"] ->
        # anonymous volume - readonly
        create_and_bind("", location, [ro: true], cont)

      [name, location, "ro"] ->
        # named volume - readonly
        create_and_bind(name, location, [ro: true], cont)

      [name, location] ->
        # named volume
        create_and_bind(name, location, [ro: false], cont)

      _ ->
        {:error, "could not decode volume specfication string"}
    end
  end

  defp create_and_bind("", location, opts, cont) do
    name = Kleened.Core.Utils.uuid()
    vol = Volume.create(name)
    Volume.bind_volume(cont, vol, location, opts)
  end

  defp create_and_bind(name, location, opts, cont) do
    vol = MetaData.get_volume(name)
    Volume.bind_volume(cont, vol, location, opts)
  end

  def running_jails() do
    {jails_json, 0} = System.cmd("jls", ["-v", "--libxo=json"], stderr_to_stdout: true)
    {:ok, jails} = Jason.decode(jails_json)
    jails = Enum.map(jails["jail-information"]["jail"], & &1["name"])
    jails
  end
end
