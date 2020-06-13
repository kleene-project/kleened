defmodule Jocker.Engine.Volume do
  alias Jocker.Engine.ZFS
  alias Jocker.Engine.Config
  alias Jocker.Engine.Utils
  alias Jocker.Engine.MetaData
  import Jocker.Engine.Records
  require Config
  require Logger

  @type bind_opts() :: [
          rw: boolean()
        ]

  @spec initialize() :: :ok
  def initialize() do
    ZFS.create(Config.get(:volume_root))
    :ok
  end

  @spec create_volume(String.t()) :: Jocker.Engine.Records.volume()
  def create_volume(name) do
    dataset = Path.join(Config.get(:volume_root), name)
    mountpoint = Path.join("/", dataset)
    ZFS.create(dataset)

    vol =
      volume(
        name: name,
        dataset: dataset,
        mountpoint: mountpoint,
        created: Utils.timestamp_now()
      )

    MetaData.add_volume(vol)
    Logger.debug("Volume created: #{inspect(vol)}")
    vol
  end

  @spec destroy_volume(Jocker.Engine.Records.volume()) :: :ok
  def destroy_volume(volume(dataset: dataset) = vol) do
    mounts = MetaData.remove_mounts_by_volume(vol)
    Enum.map(mounts, fn mount(location: location) -> 0 = Utils.unmount(location) end)
    ZFS.destroy(dataset)
    MetaData.remove_volume(vol)
    :ok
  end

  @spec destroy_mounts(Jocker.Engine.Records.container()) :: :ok
  def destroy_mounts(container) do
    mounts = MetaData.remove_mounts_by_container(container)
    Enum.map(mounts, fn mount(location: location) -> 0 = Utils.unmount(location) end)
  end

  @spec bind_volume(
          Jocker.Engine.Records.container(),
          Jocker.Engine.Records.volume(),
          String.t(),
          bind_opts()
        ) :: :ok
  def bind_volume(
        container(id: container_id, layer_id: layer_id),
        volume(name: volume_name, mountpoint: volume_mountpoint),
        location,
        opts \\ []
      ) do
    layer(mountpoint: container_mountpoint) = MetaData.get_layer(layer_id)
    absolute_location = Path.join(container_mountpoint, location)
    read_only = Keyword.get(opts, :ro, false)

    case read_only do
      false ->
        mount_nullfs([volume_mountpoint, absolute_location])

      true ->
        mount_nullfs(["-o", "ro", volume_mountpoint, absolute_location])
    end

    mnt =
      mount(
        container_id: container_id,
        volume_name: volume_name,
        location: absolute_location,
        read_only: read_only
      )

    MetaData.add_mount(mnt)
    :ok
  end

  defp mount_nullfs(args) do
    {"", 0} = System.cmd("/sbin/mount_nullfs", args)
  end
end
