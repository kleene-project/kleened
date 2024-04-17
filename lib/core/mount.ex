defmodule Kleened.Core.Mount do
  alias Kleened.Core.{OS, FreeBSD, Config, Volume, ZFS, MetaData}
  alias Kleened.API.Schemas
  require Config
  require Logger

  @spec create(
          %Schemas.Container{},
          %Schemas.MountPointConfig{}
        ) :: {:ok, %Schemas.MountPoint{}}
  def create(container, %Schemas.MountPointConfig{type: "volume"} = config) do
    volume =
      case MetaData.get_volume(config.source) do
        %Schemas.Volume{} = volume -> volume
        :not_found -> Volume.create(config.source)
      end

    mountpoint = ZFS.mountpoint(container.dataset)
    absolute_destination = Path.join(mountpoint, config.destination)

    case create_directory(absolute_destination) do
      :ok ->
        case populate_volume_if_empty(absolute_destination, volume) do
          :ok ->
            mountpoint = %Schemas.MountPoint{
              type: "volume",
              container_id: container.id,
              source: volume.name,
              destination: config.destination,
              read_only: config.read_only
            }

            MetaData.add_mount(mountpoint)
            {:ok, mountpoint}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec create(
          %Schemas.Container{},
          %Schemas.MountPointConfig{}
        ) :: {:ok, %Schemas.MountPoint{}}
  def create(container, %Schemas.MountPointConfig{type: "nullfs"} = config) do
    mountpoint = ZFS.mountpoint(container.dataset)
    absolute_destination = Path.join(mountpoint, config.destination)

    case create_directory_or_file(absolute_destination, config.source) do
      :ok ->
        mountpoint = %Schemas.MountPoint{
          type: "nullfs",
          container_id: container.id,
          source: config.source,
          destination: config.destination,
          read_only: config.read_only
        }

        MetaData.add_mount(mountpoint)
        {:ok, mountpoint}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec mount(
          %Schemas.Container{},
          %Schemas.MountPoint{}
        ) :: :ok | {:error, String.t()}
  def mount(container, %Schemas.MountPoint{type: "volume"} = mountpoint) do
    case MetaData.get_volume(mountpoint.source) do
      :not_found ->
        msg = "could not mount volume #{mountpoint.source} into container #{container.id}"
        Logger.warning(msg)
        {:error, msg}

      volume ->
        Logger.debug("mounting #{inspect(mountpoint)} into container #{container.id}")
        create_nullfs_mount(container, volume.mountpoint, mountpoint)
    end
  end

  def mount(container, %Schemas.MountPoint{type: "nullfs"} = mountpoint) do
    Logger.debug("mounting #{inspect(mountpoint)} into container #{container.id}")
    create_nullfs_mount(container, mountpoint.source, mountpoint)
  end

  @spec unmount(%Schemas.MountPoint{} | String.t()) :: {:error, String.t()} | :ok
  def unmount(%Schemas.MountPoint{container_id: container_id, destination: destination}) do
    %Schemas.Container{dataset: dataset} = MetaData.get_container(container_id)
    container_mountpoint = ZFS.mountpoint(dataset)
    dest = Path.join(container_mountpoint, destination)
    unmount(dest)
  end

  def unmount(dest) when is_binary(dest) do
    case is_nullfs_mounted?(dest) do
      true ->
        case OS.cmd(["/sbin/umount", dest]) do
          {_output, 0} ->
            :ok

          {output, _nonzero_exitcode} ->
            {:error, output}
        end

      false ->
        :ok
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

  defp populate_volume_if_empty(absolute_destination, volume) do
    case OS.cmd(~w"/bin/ls -AB #{absolute_destination}") do
      {"", 0} ->
        :ok

      {_nonempty, 0} ->
        case OS.shell("/bin/cp -a #{absolute_destination}/* #{volume.mountpoint}") do
          {_, 0} -> :ok
          {output, _non_zero_exit} -> {:error, output}
        end

      {output, _non_zero_exit} ->
        {:error, output}
    end
  end

  defp create_nullfs_mount(container, source, mountpoint) do
    zfs_mountpoint = ZFS.mountpoint(container.dataset)
    destination_on_host = Path.join(zfs_mountpoint, mountpoint.destination)

    mount_cmd =
      case mountpoint.read_only do
        false -> ["/sbin/mount_nullfs", source, destination_on_host]
        true -> ["/sbin/mount_nullfs", "-o", "ro", source, destination_on_host]
      end

    remove_conflicting_mount_if_exists(source, destination_on_host)

    case OS.cmd(mount_cmd) do
      {"", 0} -> :ok
      {output, _nonzero_exitcode} -> {:error, output}
    end
  end

  defp remove_conflicting_mount_if_exists(src, dest) do
    FreeBSD.mounts()
    |> Enum.drop_while(fn
      %{"fstype" => "nullfs", "special" => ^src, "node" => ^dest} ->
        Logger.info("Removing conflicting nullfs-mount on #{dest}")
        unmount(dest)
        false

      _ ->
        true
    end)
  end

  defp is_nullfs_mounted?(dest) do
    FreeBSD.mounts()
    |> Enum.any?(fn
      %{"fstype" => "nullfs", "node" => ^dest} ->
        true

      _ ->
        false
    end)
  end

  defp create_directory_or_file(destination, source) do
    source = File.stat(source)
    create_directory_or_file_(destination, source)
  end

  defp create_directory_or_file_(destination, {:ok, %File.Stat{type: :directory}}) do
    create_directory(destination)
  end

  defp create_directory_or_file_(destination, {:ok, %File.Stat{type: :regular}}) do
    case create_directory(Path.dirname(destination)) do
      :ok ->
        case File.touch(destination) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, "could not create destination file: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_directory_or_file_(_destination, {:ok, _stat}) do
    {:error, "could not determine source type, must be either directory or regular file"}
  end

  defp create_directory_or_file_(_destination, {:error, reason}) do
    {:error, "error ocurred while determining source type: #{inspect(reason)}"}
  end

  defp create_directory(destination) do
    case OS.cmd(["/bin/mkdir", "-p", destination]) do
      {"", 0} ->
        :ok

      # We can catch a specific error to determine if 'destination' is a file
      {output, _nonzero_exitcode} ->
        {:error, output}
    end
  end
end
