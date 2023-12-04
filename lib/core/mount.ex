defmodule Kleened.Core.Mount do
  alias Kleened.Core.{OS, Config, Utils, Layer, MetaData}
  alias Kleened.API.Schemas
  require Config
  require Logger

  @type bind_opts() :: [
          rw: boolean()
        ]

  @spec mount_volume(
          %Schemas.Container{},
          %Schemas.Volume{},
          String.t(),
          bind_opts()
        ) :: :ok
  def mount_volume(
        %Schemas.Container{id: container_id, layer_id: layer_id},
        %Schemas.Volume{name: volume_name, mountpoint: volume_mountpoint},
        destination,
        opts \\ []
      ) do
    read_only = Keyword.get(opts, :ro, false)
    create_nullfs_mount_(layer_id, volume_mountpoint, destination, read_only)

    mnt = %Schemas.MountPoint{
      type: "volume",
      container_id: container_id,
      source: volume_name,
      destination: destination,
      read_only: read_only
    }

    MetaData.add_mount(mnt)
    :ok
  end

  @spec mount_nullfs(
          %Schemas.Container{},
          String.t(),
          bind_opts()
        ) :: {:error, String.t()} | {:ok, %Schemas.MountPoint{}}
  def mount_nullfs(
        %Schemas.Container{id: container_id, layer_id: layer_id},
        source,
        destination,
        opts \\ []
      ) do
    read_only = Keyword.get(opts, :ro, false)
    create_nullfs_mount_(layer_id, source, destination, read_only)

    mountpoint = %Schemas.MountPoint{
      type: "nullfs",
      container_id: container_id,
      source: source,
      destination: destination,
      read_only: read_only
    }

    MetaData.add_mount(mountpoint)
    {:ok, mountpoint}
  end

  @spec unmount(%Schemas.MountPoint{}) :: {:error, String.t()} | :ok
  def unmount(%Schemas.MountPoint{container_id: container_id, destination: destination}) do
    %Schemas.Container{layer_id: layer_id} = MetaData.get_container(container_id)
    %Layer{mountpoint: container_mountpoint} = MetaData.get_layer(layer_id)
    dest = Path.join(container_mountpoint, destination)

    case OS.cmd(["/sbin/umount", dest]) do
      {_output, 0} ->
        :ok

      {output, _nonzero_exitcode} ->
        {:error, output}
    end
  end

  @spec remove_mounts(%Schemas.Volume{} | %Schemas.Container{}) :: :ok
  def remove_mounts(%Schemas.Volume{} = volume) do
    mounts = MetaData.remove_mounts(volume)
    Enum.map(mounts, fn mountpoint -> unmount(mountpoint) end)
    :ok
  end

  def remove_mounts(%Schemas.Container{} = container) do
    mounts = MetaData.remove_mounts(container)
    Enum.map(mounts, fn mountpoint -> unmount(mountpoint) end)
    :ok
  end

  defp create_nullfs_mount_(layer_id, source, destination, read_only) do
    %Layer{mountpoint: mountpoint} = MetaData.get_layer(layer_id)
    destination = Path.join(mountpoint, destination)
    {"", 0} = OS.cmd(["/bin/mkdir", "-p", destination])

    case read_only do
      false ->
        {"", 0} = OS.cmd(["/sbin/mount_nullfs", source, destination])

      true ->
        {"", 0} = OS.cmd(["/sbin/mount_nullfs", "-o", "ro", source, destination])
    end
  end
end
