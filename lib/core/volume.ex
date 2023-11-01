defmodule Kleened.Core.Volume do
  alias Kleened.Core.{ZFS, Config, Utils, Layer, MetaData}
  alias Kleened.API.Schemas
  require Config
  require Logger

  alias __MODULE__, as: Volume

  @type t() :: %Schemas.Volume{}

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
    destroy_(name)
  end

  @spec prune() :: {:ok, [String.t()]}
  def prune() do
    pruned_volumes =
      MetaData.list_unused_volumes()
      |> Enum.map(fn keywords ->
        volume_name = Keyword.get(keywords, :name)
        destroy_(volume_name)
        volume_name
      end)

    {:ok, pruned_volumes}
  end

  @spec inspect_(String.t()) :: {:ok, %Schemas.VolumeInspect{}} | {:error, String.t()}
  def inspect_(name) do
    case MetaData.get_volume(name) do
      :not_found ->
        {:error, "No such volume"}

      volume ->
        mounts = MetaData.list_mounts(volume)
        {:ok, %Schemas.VolumeInspect{volume: volume, mountpoints: mounts}}
    end
  end

  @spec destroy_mounts(%Schemas.Container{}) :: :ok
  def destroy_mounts(container) do
    mounts = MetaData.remove_mounts(container)

    Enum.map(mounts, fn %Schemas.MountPoint{location: location} -> 0 = Utils.unmount(location) end)
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
    host_location = Path.join(container_mountpoint, location)
    Utils.mkdir(host_location)
    read_only = Keyword.get(opts, :ro, false)

    case read_only do
      false ->
        {"", 0} = Utils.mount_nullfs([volume_mountpoint, host_location])

      true ->
        {"", 0} = Utils.mount_nullfs(["-o", "ro", volume_mountpoint, host_location])
    end

    mnt = %Schemas.MountPoint{
      container_id: container_id,
      volume_name: volume_name,
      location: host_location,
      read_only: read_only
    }

    MetaData.add_mount(mnt)
    :ok
  end

  defp destroy_(name) do
    case Kleened.Core.MetaData.get_volume(name) do
      :not_found ->
        {:error, "No such volume"}

      volume ->
        mounts = MetaData.remove_mounts(volume)

        Enum.map(mounts, fn %Schemas.MountPoint{location: location} ->
          0 = Utils.unmount(location)
        end)

        ZFS.destroy(volume.dataset)
        MetaData.remove_volume(volume)
        :ok
    end
  end
end
