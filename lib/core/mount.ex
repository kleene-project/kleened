defmodule Kleened.Core.Mount do
  alias Kleened.Core.{OS, Config, Volume, Layer, MetaData}
  alias Kleened.API.Schemas
  require Config
  require Logger

  @type bind_opts() :: [
          rw: boolean()
        ]

  @spec create(
          %Schemas.Container{},
          %Schemas.MountPointConfig{}
        ) :: {:ok, %Schemas.MountPoint{}}
  def create(
        container,
        %Schemas.MountPointConfig{
          type: "volume",
          source: volume_name,
          destination: destination,
          read_only: read_only
        }
      ) do
    source =
      case MetaData.get_volume(volume_name) do
        %Schemas.Volume{} = volume ->
          volume.mountpoint

        :not_found ->
          volume = Volume.create(volume_name)
          volume.mountpoint
      end

    case create_nullfs_mount(container, source, destination, read_only) do
      {:ok, mountpoint} ->
        mountpoint = %Schemas.MountPoint{mountpoint | type: "volume", source: volume_name}
        MetaData.add_mount(mountpoint)
        {:ok, mountpoint}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create(
          %Schemas.Container{},
          %Schemas.MountPointConfig{}
        ) :: {:ok, %Schemas.MountPoint{}}
  def create(
        container,
        %Schemas.MountPointConfig{
          type: "nullfs",
          source: source,
          destination: destination,
          read_only: read_only
        }
      ) do
    case create_nullfs_mount(container, source, destination, read_only) do
      {:ok, mountpoint} ->
        mountpoint = %Schemas.MountPoint{mountpoint | type: "nullfs", source: source}
        MetaData.add_mount(mountpoint)
        {:ok, mountpoint}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp create_nullfs_mount(
         %Schemas.Container{id: container_id, layer_id: layer_id},
         source,
         destination,
         read_only
       ) do
    %Layer{mountpoint: mountpoint} = MetaData.get_layer(layer_id)
    absolute_destination = Path.join(mountpoint, destination)

    case OS.cmd(["/bin/mkdir", "-p", absolute_destination]) do
      {"", 0} ->
        mount_cmd =
          case read_only do
            false -> ["/sbin/mount_nullfs", source, absolute_destination]
            true -> ["/sbin/mount_nullfs", "-o", "ro", source, absolute_destination]
          end

        case OS.cmd(mount_cmd) do
          {"", 0} ->
            mountpoint = %Schemas.MountPoint{
              container_id: container_id,
              destination: destination,
              read_only: read_only
            }

            {:ok, mountpoint}

          {output, _nonzero_exitcode} ->
            {:error, output}
        end

      {output, _nonzero_exitcode} ->
        {:error, output}
    end
  end
end
