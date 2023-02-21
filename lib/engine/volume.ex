defmodule Kleened.Core.Volume do
  alias Kleened.Core.{ZFS, Config, Utils, Layer, MetaData}
  alias Kleened.API.Schemas
  require Config
  require Logger

  alias __MODULE__, as: Volume

  @type t() :: %Schemas.Volume{}

  defmodule Mount do
    @derive Jason.Encoder
    defstruct([:container_id, :volume_name, :location, read_only: false])

    @type t() ::
            %Mount{
              container_id: String.t(),
              volume_name: String.t(),
              location: String.t(),
              read_only: boolean()
            }
  end

  @type bind_opts() :: [
          rw: boolean()
        ]

  @spec create(String.t()) :: Volume.t()
  def create(name) do
    case MetaData.get_volume(name) do
      :not_found ->
        dataset = Path.join(Config.get("volume_root"), name)
        mountpoint = Path.join("/", dataset)
        ZFS.create(dataset)

        volume = %Schemas.Volume{
          name: name,
          dataset: dataset,
          mountpoint: mountpoint,
          created: Utils.timestamp_now()
        }

        MetaData.add_volume(volume)
        Logger.debug("Volume created: #{inspect(volume)}")
        volume

      %Schemas.Volume{} = volume ->
        volume
    end
  end

  @spec destroy(String.t()) :: :ok | {:error, String.t()}
  def destroy(name) do
    case Kleened.Core.MetaData.get_volume(name) do
      :not_found ->
        {:error, "No such volume"}

      volume ->
        mounts = MetaData.remove_mounts(volume)
        Enum.map(mounts, fn %Mount{location: location} -> 0 = Utils.unmount(location) end)
        ZFS.destroy(volume.dataset)
        MetaData.remove_volume(volume)
        :ok
    end
  end

  @spec destroy_mounts(%Schemas.Container{}) :: :ok
  def destroy_mounts(container) do
    mounts = MetaData.remove_mounts(container)
    Enum.map(mounts, fn %Mount{location: location} -> 0 = Utils.unmount(location) end)
  end

  @spec bind_volume(
          %Schemas.Container{},
          Kleened.Core.Records.volume(),
          String.t(),
          bind_opts()
        ) :: :ok
  def bind_volume(
        %Schemas.Container{id: container_id, layer_id: layer_id},
        %Schemas.Volume{name: volume_name, mountpoint: volume_mountpoint},
        location,
        opts \\ []
      ) do
    %Layer{mountpoint: container_mountpoint} = MetaData.get_layer(layer_id)
    absolute_location = Path.join(container_mountpoint, location)
    read_only = Keyword.get(opts, :ro, false)

    case read_only do
      false ->
        Utils.mount_nullfs([volume_mountpoint, absolute_location])

      true ->
        Utils.mount_nullfs(["-o", "ro", volume_mountpoint, absolute_location])
    end

    mnt = %Mount{
      container_id: container_id,
      volume_name: volume_name,
      location: absolute_location,
      read_only: read_only
    }

    MetaData.add_mount(mnt)
    :ok
  end
end
