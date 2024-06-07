defmodule Kleened.Core.ImageCreate do
  alias Kleened.Core.{Const, ZFS, Utils, OS}
  alias Kleened.API.Schemas
  alias Schemas.ImageCreateConfig, as: Config
  require Logger

  @type create_config() :: %Schemas.ImageCreateConfig{}
  @type freebsd_version() :: {String.t(), String.t(), String.t()}

  @spec start_image_creation(create_config()) :: {:ok, %Schemas.Image{}} | {:error, String.t()}
  def start_image_creation(%Config{method: "fetch-auto"} = config) do
    receiver = self()
    Process.spawn(fn -> create_image_using_fetch_automatically(receiver, config) end, [:link])
  end

  def start_image_creation(%Config{method: "fetch"} = config) do
    receiver = self()
    Process.spawn(fn -> create_image_using_fetch(receiver, config) end, [:link])
  end

  def start_image_creation(%Config{method: "zfs-copy"} = config) do
    receiver = self()
    Process.spawn(fn -> create_using_zfs_copy(receiver, config) end, [:link])
  end

  def start_image_creation(%Config{method: "zfs-clone"} = config) do
    receiver = self()
    Process.spawn(fn -> create_using_zfs_clone(receiver, config) end, [:link])
  end

  defp create_using_zfs_copy(
         receiver,
         %Config{zfs_dataset: dataset_parent, tag: tag} = config
       ) do
    # Initialize
    image_id = Utils.uuid()
    validate_dataset(config.zfs_dataset, receiver)
    image_dataset = Const.image_dataset(image_id)
    image = create_image_metadata(image_id, image_dataset, tag)
    snapshot_parent = dataset_parent <> "@#{image_id}"
    create_snapshot(snapshot_parent, receiver)

    # Create image dataset by zfs send/receiving it to the new image dataset
    send_msg(receiver, {:info, "copying dataset into the new image, this can take a while...\n"})
    copy_zfs_dataset(snapshot_parent, image_dataset, receiver)

    # Wrap up
    image_mountpoint = ZFS.mountpoint(image_dataset)
    copy_resolv_conf_if_dns_enabled(receiver, image_mountpoint, config)
    copy_localtime_if_enabled(receiver, image_mountpoint, config)
    freebsd_update(receiver, image_mountpoint, config)
    create_snapshot(Const.image_snapshot(image_dataset), receiver)
    send_msg(receiver, {:ok, image})
    ZFS.destroy(snapshot_parent)
  end

  defp create_using_zfs_clone(
         receiver,
         %Config{zfs_dataset: dataset_parent, tag: tag} = config
       ) do
    image_id = Utils.uuid()
    validate_dataset(config.zfs_dataset, receiver)
    image_dataset = Const.image_dataset(image_id)
    image = create_image_metadata(image_id, image_dataset, tag)
    snapshot_parent = dataset_parent <> "@#{image_id}"
    create_snapshot(snapshot_parent, receiver)

    # Create image dataset by cloning the supplied dataset
    send_msg(receiver, {:info, "cloning dataset...\n"})
    clone_zfs_dataset(snapshot_parent, image_dataset, receiver)

    # Wrap up
    image_mountpoint = ZFS.mountpoint(image_dataset)
    copy_resolv_conf_if_dns_enabled(receiver, image_mountpoint, config)
    copy_localtime_if_enabled(receiver, image_mountpoint, config)
    freebsd_update(receiver, image_mountpoint, config)
    create_snapshot(Const.image_snapshot(image_dataset), receiver)
    send_msg(receiver, {:ok, image})
  end

  defp create_image_using_fetch(receiver, config) do
    image = create_image_using_fetch_(receiver, config)
    send_msg(receiver, {:ok, image})
  end

  defp create_image_using_fetch_automatically(receiver, config) do
    {"FreeBSD", version, arch} = detect_freebsd_version()

    tag =
      case config do
        %Config{autotag: true} -> "FreeBSD-#{version}"
        %Config{autotag: false} -> config.tag
      end

    url = version2url(version, arch, "base.txz")
    image = create_image_using_fetch_(receiver, %Config{config | url: url, tag: tag})

    msg = "Created image from the automatically detected version: FreeBSD-#{version} #{arch}.\n"
    send_msg(receiver, {:info, msg})
    send_msg(receiver, {:ok, image})
  end

  defp create_image_using_fetch_(receiver, %Config{url: url, tag: tag} = config) do
    image_id = Utils.uuid()
    image_dataset = Const.image_dataset(image_id)
    tar_archive = Path.join("/", Kleened.Core.Config.get("kleene_root")) |> Path.join("base.txz")

    # Fetch tar-archive and extract it to the new image dataset
    fetch_file_from_url(url, tar_archive, receiver)

    send_msg(receiver, {:info, "Succesfully fetched base system.\n"})
    send_msg(receiver, {:info, "Unpacking contents and creating image...\n"})
    create_dataset(image_dataset, receiver)
    image_mountpoint = ZFS.mountpoint(image_dataset)
    untar_file(tar_archive, image_mountpoint, receiver)
    copy_resolv_conf_if_dns_enabled(receiver, image_mountpoint, config)
    copy_localtime_if_enabled(receiver, image_mountpoint, config)
    freebsd_update(receiver, image_mountpoint, config)
    create_snapshot(Const.image_snapshot(image_dataset), receiver)

    image = create_image_metadata(image_id, image_dataset, tag)
    File.rm(tar_archive)
    image
  end

  @spec detect_freebsd_version() :: freebsd_version()
  defp detect_freebsd_version() do
    {output, 0} = OS.cmd(["/usr/bin/uname", "-rms"])
    [operating_system, verison, architecture] = decode_uname_output(output)
    {operating_system, verison, architecture}
  end

  defp version2url(version, arch, filename) do
    hostname = "https://download.freebsd.org"

    case String.split(version, "-") do
      [_, "RELEASE"] -> "#{hostname}/releases/#{arch}/#{version}/#{filename}"
      [_, "STABLE"] -> "#{hostname}/snapshots/#{arch}/#{version}/#{filename}"
    end
  end

  defp fetch_file_from_url(url, output_file, receiver) do
    port = OS.cmd_async(["/usr/bin/fetch", url, "-o", output_file], true)

    case process_messages(port, receiver) do
      :ok -> :ok
      :error -> exit(receiver, "could not fetch file from url")
    end
  end

  defp untar_file(tar_archive, image_mountpoint, receiver) do
    port =
      OS.cmd_async(
        ["/usr/bin/tar", "-vxf", tar_archive, "-C", image_mountpoint, "--unlink"],
        true
      )

    case process_tar_messages(port, receiver, 0, 0) do
      :ok ->
        send_msg(receiver, {:info, "Succesfully extracted binaries, creating image...\n"})

      :error ->
        exit(receiver, "could not extract tar archive\n")
    end
  end

  defp process_messages(port, receiver) do
    receive do
      {^port, {:data, fetch_output}} ->
        send_msg(receiver, {:info, fetch_output})
        process_messages(port, receiver)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, _nonzero_exit_code}} ->
        :error
    end
  end

  defp process_tar_messages(port, receiver, files_processed, status_files_processed) do
    receive do
      {^port, {:data, output}} ->
        recent_processed_files = length(String.split(output, "\n"))
        files_processed = files_processed + recent_processed_files

        case files_processed - status_files_processed do
          n when n < 100 ->
            process_tar_messages(
              port,
              receiver,
              files_processed,
              status_files_processed
            )

          _ ->
            send_msg(receiver, {:info, "Extracted #{files_processed} files...\n"})

            process_tar_messages(
              port,
              receiver,
              files_processed,
              files_processed
            )
        end

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, _nonzero_exit_code}} ->
        :error
    end
  end

  defp validate_dataset(dataset, receiver) do
    if not ZFS.exists?(dataset) do
      exit(receiver, "invalid dataset")
    end
  end

  defp create_dataset(dataset, receiver) do
    case ZFS.create(dataset) do
      {_, 0} -> :ok
      {output, _exitcode} -> exit(receiver, "error creating dataset #{dataset}: #{output}")
    end
  end

  defp create_snapshot(snapshot, receiver) do
    case ZFS.snapshot(snapshot) do
      {_, 0} ->
        :ok

      {output, _exitcode} ->
        exit(receiver, "could not create snapshot #{snapshot}: #{output}")
    end
  end

  defp copy_zfs_dataset(snapshot, dataset, receiver) do
    cmd = "/sbin/zfs send -v #{snapshot} | /sbin/zfs receive #{dataset}"
    port = OS.cmd_async(["/bin/sh", "-c", cmd])

    case process_messages(port, receiver) do
      :ok -> :ok
      :error -> exit(receiver, "error copying image dataset")
    end
  end

  defp clone_zfs_dataset(snapshot, dataset, receiver) do
    cmd = "/sbin/zfs clone #{snapshot} #{dataset}"
    port = OS.cmd_async(["/bin/sh", "-c", cmd])

    case process_messages(port, receiver) do
      :ok -> :ok
      :error -> exit(receiver, "error cloning image dataset")
    end
  end

  defp copy_resolv_conf_if_dns_enabled(_receiver, _image_mountpoint, %{dns: false}) do
    :ok
  end

  defp copy_resolv_conf_if_dns_enabled(receiver, image_mountpoint, %{dns: true}) do
    source = "/etc/resolv.conf"
    dest = Path.join(image_mountpoint, ["etc/resolv.conf"])
    copy_host_file(receiver, source, dest)
  end

  defp copy_localtime_if_enabled(_receiver, _image_mountpoint, %{localtime: false}) do
    :ok
  end

  defp copy_localtime_if_enabled(receiver, image_mountpoint, %{localtime: true}) do
    source = "/etc/localtime"

    case File.stat(source) do
      {:ok, _} ->
        dest = Path.join(image_mountpoint, ["etc/localtime"])
        copy_host_file(receiver, source, dest)

      {:error, :enoent} ->
        send_msg(receiver, {:info, "/etc/localtime not found on host, skipping...\n"})
    end
  end

  defp copy_host_file(receiver, source, dest) do
    case OS.cmd(["/bin/cp", source, dest]) do
      {_output, 0} ->
        :ok

      {output, nonzero_exit} ->
        exit(
          receiver,
          "exit code #{nonzero_exit} when copying host '#{source}' to #{dest}: #{output}"
        )
    end
  end

  defp freebsd_update(_receiver, _image_mountpoint, %{update: false}) do
    :ok
  end

  defp freebsd_update(receiver, image_root, %{update: true}) do
    cmd = [
      "/bin/sh",
      "-c",
      "/usr/sbin/freebsd-update -b #{image_root} fetch --not-running-from-cron > /dev/null"
    ]

    port = OS.cmd_async(cmd, true)

    case process_messages(port, receiver) do
      :ok -> :ok
      :error -> exit(receiver, "could update base image with 'freebsd-update'")
    end

    cmd = ~w"/usr/sbin/freebsd-update -b #{image_root} install"
    port = OS.cmd_async(cmd, true)

    case process_messages(port, receiver) do
      :ok -> :ok
      :error -> exit(receiver, "could update base image with 'freebsd-update'")
    end
  end

  defp create_image_metadata(image_id, dataset, tag) do
    {name, tag} = Utils.decode_tagname(tag)

    image = %Schemas.Image{
      id: image_id,
      user: "root",
      name: name,
      tag: tag,
      cmd: ["/bin/sh", "/etc/rc"],
      env: [],
      created: DateTime.to_iso8601(DateTime.utc_now()),
      dataset: dataset
    }

    Kleened.Core.MetaData.add_image(image)
    image
  end

  defp decode_uname_output(output) do
    output = String.trim(output)
    String.split(output, " ")
  end

  defp exit(receiver, error_msg) do
    send_msg(receiver, {:error, error_msg})
    Process.exit(self(), :normal)
  end

  defp send_msg(pid, msg) do
    full_msg = {:image_creator, self(), msg}
    :ok = Process.send(pid, full_msg, [])
  end
end
