defmodule Kleened.Core.ImageCreate do
  alias Kleened.Core.{Const, ZFS, Utils, OS}
  alias Kleened.Core.{OCI, MetaData}
  alias Kleened.Core.Registry
  alias Kleened.API.Schemas
  alias Schemas.ImageCreateConfig, as: Config
  require Logger

  @type create_config() :: Schemas.ImageCreateConfig.t()
  @type freebsd_version() :: {String.t(), String.t(), String.t()}

  @spec create(create_config()) :: {:ok, String.t(), pid()}
  def create(config) do
    client = self()
    image_id = Utils.uuid()

    worker =
      case config.method do
        "zfs-clone" ->
          fn -> create_using_zfs_clone(client, image_id, config) end

        "zfs-copy" ->
          fn -> create_using_zfs_copy(client, image_id, config) end

        "fetch" ->
          fn -> create_image_using_fetch(client, image_id, config) end

        "fetch-auto" ->
          fn -> create_image_using_fetch_auto(client, image_id, config) end
      end

    {:ok, image_id, Process.spawn(worker, [:link])}
  end

  @doc """
  Import an image from an OCI image layout archive (the `.txz` files published
  on download.freebsd.org are OCI layouts). The archive is fetched from `url`
  (or copied, when it is a local path), unpacked to a temporary directory,
  and materialized into a new image dataset layer by layer.

  Reports progress to the calling process as `{:image_creator, pid, msg}`
  messages, exactly like `create/1`.
  """
  @spec import_oci(Schemas.ImageImportConfig.t()) :: {:ok, String.t(), pid()}
  def import_oci(config) do
    client = self()
    image_id = Utils.uuid()

    worker = fn -> import_oci_layout(client, image_id, config) end
    {:ok, image_id, Process.spawn(worker, [:link])}
  end

  @doc """
  Pull an image from an OCI distribution registry. The image is downloaded
  (manifest, config and layer blobs, all sha256-verified) into a temporary
  OCI layout and materialized into a new image dataset layer by layer.

  Reports progress to the calling process as `{:image_creator, pid, msg}`
  messages, exactly like `create/1` and `import_oci/1`.
  """
  @spec pull_oci(Schemas.ImagePullConfig.t()) :: {:ok, String.t(), pid()}
  def pull_oci(config) do
    client = self()
    image_id = Utils.uuid()

    worker = fn -> pull_oci_layout(client, image_id, config) end
    {:ok, image_id, Process.spawn(worker, [:link])}
  end

  defp pull_oci_layout(receiver, image_id, %Schemas.ImagePullConfig{ref: ref, platform: platform}) do
    progress = fn msg -> send_msg(receiver, {:info, msg}) end
    pull_opts = [progress: progress] |> pull_platform(platform)

    with {:ok, parsed} <- parse_pull_ref(ref),
         {:ok, layout} <- Registry.pull(ref, pull_opts),
         {:existing, existing_image} <- skip_if_pulled(layout, parsed),
         {:ok, image} <-
           materialize_unless_exists(
             existing_image,
             layout,
             image_id,
             pull_tag(parsed),
             receiver
           ) do
      File.rm_rf!(layout.root)
      send_msg(receiver, {:ok, image})
    else
      {:error, reason} ->
        send_msg(receiver, {:error, reason})

      {:crash, reason} ->
        exit(receiver, reason)
    end
  end

  defp parse_pull_ref(ref) do
    case OCI.Ref.parse(ref) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, "invalid image reference #{ref}"}
    end
  end

  defp pull_platform(opts, nil), do: opts

  defp pull_platform(opts, platform) do
    Keyword.put(opts, :platform, List.to_tuple(String.split(platform, "/")))
  end

  # The image is tagged with repository:tag from the pulled reference.
  defp pull_tag(%OCI.Ref{} = ref), do: "#{ref.repository}:#{ref.tag || "latest"}"

  defp skip_if_pulled(%OCI.Layout{manifest_digest: digest}, %OCI.Ref{} = ref) do
    case MetaData.get_image(pull_tag(ref)) do
      %Schemas.Image{digest: ^digest} = image -> {:existing, image}
      _ -> {:existing, nil}
    end
  end

  defp import_oci_layout(receiver, image_id, %Schemas.ImageImportConfig{url: url} = config) do
    with {:ok, archive} <- fetch_oci_archive(url, receiver),
         {:ok, layout_root} <- unpack_oci_layout(archive),
         {:ok, layout} <- open_oci_layout(layout_root, config, receiver),
         {:existing, existing_image} <- skip_if_imported(layout, config),
         {:ok, image} <-
           materialize_unless_exists(existing_image, layout, image_id, config.tag, receiver) do
      File.rm_rf!(layout_root)
      send_msg(receiver, {:ok, image})
    else
      {:error, reason} ->
        send_msg(receiver, {:error, reason})

      {:crash, reason} ->
        exit(receiver, reason)
    end
  end

  # An already-imported image (same manifest digest under the same name:tag)
  # is returned as-is; otherwise the layout is materialized into a new image.
  defp materialize_unless_exists(nil, layout, image_id, tag, receiver) do
    with :ok <- materialize_layers(layout, image_id, receiver) do
      register_oci_image(layout, image_id, tag)
    end
  end

  defp materialize_unless_exists(existing_image, _layout, _image_id, _config, _receiver) do
    {:ok, existing_image}
  end

  # Skip-if-exists: an image with the same manifest digest already imported
  # under the same name:tag is returned as success (idempotent re-import).
  defp skip_if_imported(%OCI.Layout{manifest_digest: digest}, %Schemas.ImageImportConfig{tag: tag}) do
    {name, tag} = Utils.decode_tagname(tag)

    case Kleened.Core.MetaData.get_image("#{name}:#{tag}") do
      %Schemas.Image{digest: ^digest} = image ->
        {:existing, image}

      _ ->
        {:existing, nil}
    end
  end

  defp fetch_oci_archive("http" <> _ = url, receiver) do
    archive = Path.join(System.tmp_dir(), "kleened-oci-import-#{Utils.uuid()}.txz")
    # fetch_file_from_url/3 relays fetch(1)'s progress output to the receiver,
    # so slow downloads are not silent.
    fetch_file_from_url(url, archive, receiver)
  end

  defp fetch_oci_archive(path, _receiver) do
    case File.exists?(path) do
      true -> {:ok, path}
      false -> {:error, "no such file: #{path}"}
    end
  end

  defp unpack_oci_layout(archive) do
    layout_root = Path.join(System.tmp_dir(), "kleened-oci-layout-#{Utils.uuid()}")

    with :ok <- make_dir(layout_root),
         {_, 0} <-
           OS.cmd(["/usr/bin/tar", "-xf", archive, "-C", layout_root]) do
      {:ok, layout_root}
    else
      {:error, reason} -> {:crash, "could not create #{layout_root}: #{inspect(reason)}"}
      {output, _} -> {:crash, "could not unpack OCI archive #{archive}: #{output}"}
    end
  end

  defp make_dir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Default the platform selector to the host's own os/architecture (from
  # uname(1)) when the config does not specify one, so a multi-platform index
  # imports the image that matches the host instead of the first manifest.
  defp open_oci_layout(layout_root, %Schemas.ImageImportConfig{platform: platform}, receiver) do
    opts = [platform: platform_option(platform)] |> Keyword.reject(fn {_k, v} -> v == nil end)

    case OCI.Layout.open(layout_root, opts) do
      {:ok, layout} ->
        {:ok, layout}

      {:error, reason} ->
        send_msg(receiver, {:info, "could not open OCI layout: #{reason}\n"})
        {:error, reason}
    end
  end

  # platform comes as "freebsd/amd64" from the config schema
  defp platform_option(nil) do
    {os, _version, arch} = detect_freebsd_version()
    {String.downcase(os), arch}
  end

  defp platform_option(platform), do: List.to_tuple(String.split(platform, "/"))

  defp materialize_layers(%OCI.Layout{layers: layers, root: root}, image_id, receiver) do
    dataset = Const.image_dataset(image_id)
    total = length(layers)

    with {_, 0} <- ZFS.create(dataset) do
      mountpoint = ZFS.mountpoint(dataset)

      layers
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {descriptor, n}, :ok ->
        blob = OCI.Layout.blob_path(root, descriptor["digest"])
        msg = "extracting layer #{n}/#{total} (#{String.slice(descriptor["digest"], 7, 12)})...\n"
        send_msg(receiver, {:info, msg})

        case OCI.Layer.apply(blob, mountpoint) do
          :ok ->
            {_, 0} = ZFS.snapshot(dataset <> "@layer-#{n}")
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, "layer #{n}: #{reason}"}}
        end
      end)
    else
      {output, _} -> {:error, "could not create image dataset #{dataset}: #{output}"}
    end
  end

  defp register_oci_image(
         %OCI.Layout{config: config, manifest_digest: manifest_digest},
         image_id,
         tag
       ) do
    dataset = Const.image_dataset(image_id)
    {_, 0} = ZFS.snapshot(Const.image_snapshot(dataset))
    {name, tag} = Utils.decode_tagname(tag)
    image_config = Map.get(config, "config", %{})

    image = %Schemas.Image{
      id: image_id,
      user: Map.get(image_config, "User", "root"),
      name: name,
      tag: tag,
      cmd: Map.get(image_config, "Cmd", []),
      entrypoint: Map.get(image_config, "Entrypoint", []),
      env: Map.get(image_config, "Env", []),
      workdir: Map.get(image_config, "WorkingDir", ""),
      labels: Map.get(image_config, "Labels", %{}),
      instructions: [],
      created: Map.get(config, "created", DateTime.to_iso8601(DateTime.utc_now())),
      dataset: dataset,
      digest: manifest_digest,
      source: "oci"
    }

    MetaData.add_image(image)
    {:ok, image}
  end

  defp create_using_zfs_copy(
         receiver,
         image_id,
         %Config{zfs_dataset: dataset_parent, tag: tag} = config
       ) do
    # Initialize
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
         image_id,
         %Config{zfs_dataset: dataset_parent, tag: tag} = config
       ) do
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

  defp create_image_using_fetch(receiver, image_id, config) do
    image = create_image_using_fetch_(receiver, image_id, config)
    send_msg(receiver, {:ok, image})
  end

  defp create_image_using_fetch_auto(receiver, image_id, config) do
    {"FreeBSD", version, arch} = detect_freebsd_version()

    tag =
      case config do
        %Config{autotag: true} -> "FreeBSD-#{version}"
        %Config{autotag: false} -> config.tag
      end

    url = version2url(version, arch, "base.txz", receiver)
    image = create_image_using_fetch_(receiver, image_id, %Config{config | url: url, tag: tag})

    msg = "Created image from the automatically detected version: FreeBSD-#{version} #{arch}.\n"
    send_msg(receiver, {:info, msg})
    send_msg(receiver, {:ok, image})
  end

  defp create_image_using_fetch_(receiver, image_id, %Config{url: url, tag: tag} = config) do
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

  defp version2url(version, arch, filename, receiver) do
    hostname = "https://download.freebsd.org"

    case String.split(version, "-") do
      [_, "RELEASE"] ->
        "#{hostname}/releases/#{arch}/#{version}/#{filename}"

      # E.g. '14.1-RELEASE-p7'
      [version_number, "RELEASE", _] ->
        "#{hostname}/releases/#{arch}/#{version_number}-RELEASE/#{filename}"

      [_, "STABLE"] ->
        "#{hostname}/snapshots/#{arch}/#{version}/#{filename}"

      _ ->
        exit(receiver, "could not deduce url from FreeBSD version #{version}")
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
