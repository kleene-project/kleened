defmodule Kleened.Core.ImageCreate do
  alias Kleened.Core.{ZFS, Utils, Layer, OS}
  alias Kleened.API.Schemas
  alias Schemas.ImageCreateConfig, as: Config
  require Logger

  @type create_config() :: %Schemas.ImageCreateConfig{}
  @type freebsd_version() :: {String.t(), String.t(), String.t()}

  @spec start_image_creation(create_config()) :: {:ok, %Schemas.Image{}} | {:error, String.t()}
  def start_image_creation(%Config{method: "fetch", tag: tag, url: url, force: force}) do
    my_pid = self()
    Process.spawn(fn -> create_image_from_fetched_tarball(url, tag, my_pid, force) end, [:link])
  end

  def start_image_creation(%Config{method: "zfs", tag: tag, zfs_dataset: dataset}) do
    my_pid = self()
    Process.spawn(fn -> create_image_from_dataset(dataset, tag, my_pid) end, [:link])
  end

  defp create_image_from_dataset(dataset_parent, tag, receiver) do
    image_id = Utils.uuid()
    {image_dataset, image_mountpoint, image_snapshot} = create_image_attributes(image_id)
    snapshot_parent = dataset_parent <> "@#{image_id}"
    create_snapshot(snapshot_parent, receiver)

    # Create image dataset by zfs send/receiving it on the new image dataset
    send_msg(receiver, {:info, "copying dataset into the new image, this can take a while...\n"})
    create_dataset_from_snapshot(snapshot_parent, image_dataset, receiver)
    create_snapshot(image_snapshot, receiver)

    image = create_image_metadata(image_id, image_snapshot, image_dataset, image_mountpoint, tag)
    send_msg(receiver, {:ok, image})
    ZFS.destroy(snapshot_parent)
  end

  defp create_image_from_fetched_tarball("", tag, receiver, force) do
    {"FreeBSD", version, arch} = detect_freebsd_version(force, receiver)
    url = version2url(version, arch, "base.txz")

    send_msg(
      receiver,
      {:info, "FreeBSD-#{version} #{arch} detected."}
    )

    create_image_from_fetched_tarball(url, tag, receiver, force)
  end

  defp create_image_from_fetched_tarball(url, tag, receiver, _force) do
    image_id = Utils.uuid()
    {image_dataset, image_mountpoint, image_snapshot} = create_image_attributes(image_id)
    tar_archive = Path.join("/", [Kleened.Core.Config.get("zroot"), "base.txz"])

    # Fetch tar-archive and extract it to the new image dataset
    fetch_file_from_url(url, tar_archive, receiver)

    send_msg(
      receiver,
      {:info, "succesfully fetched base system.\nUnpacking contents and creating image..."}
    )

    create_dataset(image_dataset, receiver)
    untar_file(tar_archive, image_mountpoint, receiver)
    create_snapshot(image_snapshot, receiver)

    image = create_image_metadata(image_id, image_snapshot, image_dataset, image_mountpoint, tag)
    send_msg(receiver, {:ok, image})
    File.rm(tar_archive)
  end

  @spec detect_freebsd_version(boolean(), pid()) ::
          {:probably_local | :probably_not_local, freebsd_version()} | {:error, String.t()}
  defp detect_freebsd_version(force, receiver) do
    {output, 0} = OS.cmd(["/usr/bin/uname", "-rms"])
    [operating_system, verison, architecture] = decode_uname_output(output)

    detection = detect_local_build()

    case {force, detection} do
      {false, :probably_local} ->
        exit(
          receiver,
          "seems like the host operating system have been builded locally from source"
        )

      _ ->
        :ok
    end

    {operating_system, verison, architecture}
  end

  @spec detect_local_build() :: :probably_local | :probably_not_local
  defp detect_local_build() do
    {output, 0} = OS.cmd(["/usr/bin/uname", "-v"])
    lines = decode_uname_output(output)
    {source_root, _} = List.pop_at(lines, -1)

    case source_root do
      <<"root@", _::binary>> -> :probably_local
      _ -> :probably_not_local
    end
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
    port = OS.cmd_async(["/usr/bin/tar", "-vxf", tar_archive, "-C", image_mountpoint])

    case process_tar_messages(port, receiver, 0, 0) do
      :ok ->
        send_msg(receiver, {:info, "succesfully extracted binaries - creating image"})

      :error ->
        exit(receiver, "could not extract tar archive")
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
            send_msg(receiver, {:info, "extracted #{files_processed} files..."})

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

  defp create_dataset_from_snapshot(snapshot, dataset, receiver) do
    cmd = "/sbin/zfs send -v #{snapshot} | /sbin/zfs receive #{dataset}"
    port = OS.cmd_async(["/bin/sh", "-c", cmd])

    case process_messages(port, receiver) do
      :ok -> :ok
      :error -> exit(receiver, "error creating image dataset")
    end
  end

  defp create_image_attributes(image_id) do
    image_dataset = Path.join(Kleened.Core.Config.get("zroot"), ["image", "/", image_id])
    image_mountpoint = Path.join("/", image_dataset)
    image_snapshot = image_dataset <> "@kleene"
    {image_dataset, image_mountpoint, image_snapshot}
  end

  defp create_image_metadata(image_id, snapshot, image_dataset, image_mountpoint, tag) do
    layer = %Layer{
      id: Kleened.Core.Utils.uuid(),
      snapshot: snapshot,
      dataset: image_dataset,
      mountpoint: image_mountpoint
    }

    Kleened.Core.MetaData.add_layer(layer)
    {name, tag} = Utils.decode_tagname(tag)

    image = %Schemas.Image{
      id: image_id,
      layer_id: layer.id,
      user: "root",
      name: name,
      tag: tag,
      command: ["/bin/sh", "/etc/rc"],
      env: [],
      created: DateTime.to_iso8601(DateTime.utc_now())
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
