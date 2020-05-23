defmodule Jocker.Engine.Volume do
  alias Jocker.Engine.ZFS
  alias Jocker.Engine.Config
  alias Jocker.Engine.Utils
  alias Jocker.Engine.MetaData
  import Jocker.Engine.Records
  require Config

  @type bind_opts() :: [
          rw: boolean()
        ]

  @spec initialize() :: :ok
  def initialize() do
    ZFS.create(Config.volume_root())
    :ok
  end

  @spec create_volume(String.t()) :: Jocker.Engine.Records.volume()
  def create_volume(name \\ "") do
    name =
      case name do
        "" -> Jocker.Engine.Utils.uuid()
        _name -> name
      end

    dataset = Path.join(Config.volume_root(), name)
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
    vol
  end

  @spec delete_volume(Jocker.Engine.Records.volume()) :: :ok
  def delete_volume(volume(dataset: dataset) = vol) do
    ZFS.destroy(dataset)
    binds = MetaData.list_mounts(vol)
    Enum.map(binds, &Util.unmount/1)
    MetaData.remove_mounts(vol)
    MetaData.remove_volume(vol)
    :ok
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
    read_only = Keyword.get(opts, :rw, true)

    case read_only do
      true -> mount_nullfs([volume_mountpoint, absolute_location])
      false -> mount_nullfs(["-o", "ro", volume_mountpoint, absolute_location])
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
