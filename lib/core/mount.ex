defmodule Kleened.Core.Mount do
  alias Kleened.Core.{Config, Utils, Layer, MetaData}
  alias Kleened.API.Schemas
  require Config
  require Logger

  @type bind_opts() :: [
          rw: boolean()
        ]

  # 'remove_mounts'
  @spec destroy_mounts(%Schemas.Container{}) :: :ok
  def destroy_mounts(container) do
    mounts = MetaData.remove_mounts(container)

    Enum.map(mounts, fn %Schemas.MountPoint{destination: dest} -> Utils.unmount(dest) end)
    :ok
  end

  @spec bind_volume(
          %Schemas.Container{},
          Kleened.Core.Records.volume(),
          String.t(),
          bind_opts()
        ) :: :ok
  def bind_volume(
        %Schemas.Container{id: container_id, layer_id: layer_id},
        %Schemas.Volume{name: source, mountpoint: volume_mountpoint},
        destination,
        opts \\ []
      ) do
    %Layer{mountpoint: container_mountpoint} = MetaData.get_layer(layer_id)
    destination = Path.join(container_mountpoint, destination)
    Utils.mkdir(destination)
    read_only = Keyword.get(opts, :ro, false)

    case read_only do
      false ->
        {"", 0} = Utils.mount_nullfs([volume_mountpoint, destination])

      true ->
        {"", 0} = Utils.mount_nullfs(["-o", "ro", volume_mountpoint, destination])
    end

    mnt = %Schemas.MountPoint{
      type: "volume",
      container_id: container_id,
      source: source,
      destination: destination,
      read_only: read_only
    }

    MetaData.add_mount(mnt)
    :ok
  end
end
