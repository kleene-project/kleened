defmodule Kleened.Core.Mount do
  alias Kleened.Core.{OS, Config, Volume, ZFS, MetaData}
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
        %Schemas.Container{dataset: dataset} = container,
        %Schemas.MountPointConfig{
          type: "volume",
          source: volume_name,
          destination: destination,
          read_only: read_only
        }
      ) do
    volume =
      case MetaData.get_volume(volume_name) do
        %Schemas.Volume{} = volume -> volume
        :not_found -> Volume.create(volume_name)
      end

    mountpoint = ZFS.mountpoint(dataset)
    absolute_destination = Path.join(mountpoint, destination)

    case create_directory(absolute_destination) do
      :ok ->
        case populate_volume_if_empty(absolute_destination, volume) do
          :ok ->
            case create_nullfs_mount(container, volume.mountpoint, destination, read_only) do
              {:ok, mountpoint} ->
                mountpoint = %Schemas.MountPoint{mountpoint | type: "volume", source: volume.name}
                MetaData.add_mount(mountpoint)
                {:ok, mountpoint}

              {:error, reason} ->
                {:error, reason}
            end

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
  def create(
        container,
        %Schemas.MountPointConfig{
          type: "nullfs",
          source: source,
          destination: destination,
          read_only: read_only
        }
      ) do
    mountpoint = ZFS.mountpoint(container.dataset)
    absolute_destination = Path.join(mountpoint, destination)

    case create_directory_or_file(absolute_destination, source) do
      :ok ->
        case create_nullfs_mount(container, source, destination, read_only) do
          {:ok, mountpoint} ->
            mountpoint = %Schemas.MountPoint{mountpoint | type: "nullfs", source: source}
            MetaData.add_mount(mountpoint)
            {:ok, mountpoint}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
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

  @spec unmount(%Schemas.MountPoint{}) :: {:error, String.t()} | :ok
  def unmount(%Schemas.MountPoint{container_id: container_id, destination: destination}) do
    %Schemas.Container{dataset: dataset} = MetaData.get_container(container_id)
    container_mountpoint = ZFS.mountpoint(dataset)
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
         %Schemas.Container{id: container_id, dataset: dataset},
         source,
         destination,
         read_only
       ) do
    mountpoint = ZFS.mountpoint(dataset)
    absolute_destination = Path.join(mountpoint, destination)

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
