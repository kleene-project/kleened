defmodule Kleened.Test.Utils do
  import ExUnit.Assertions

  alias Kleened.Core.{
    Config,
    MetaData,
    Container,
    Image,
    ImageCreate,
    Network,
    OS,
    Volume,
    ZFS,
    FreeBSD
  }

  alias Kleened.API.Schemas
  require Logger

  @creation_time "2023-09-14T21:21:57.990515Z"
  def create_test_base_image() do
    {:ok, _image_id, creator_pid} =
      ImageCreate.create(%Schemas.ImageCreateConfig{
        method: "zfs-clone",
        tag: "FreeBSD:testing",
        zfs_dataset: "zroot/kleene_basejail"
      })

    image = process_image_creator_messages(creator_pid)
    MetaData.add_image(%Schemas.Image{image | created: @creation_time})
    :ok
  end

  def get_host_state() do
    %Schemas.Image{dataset: test_image_dataset} = MetaData.get_image("FreeBSD:testing")

    addresses =
      list_host_addresses()
      |> Enum.map(fn %{"name" => name, "network" => network, "address" => address} ->
        %{"name" => name, "network" => network, "address" => address}
      end)
      |> MapSet.new()

    mount_devfs = get_kleene_devfs_mounts()

    datasets = get_kleene_datasets()

    %{
      addresses: addresses,
      mount_devfs: mount_devfs,
      datasets: datasets,
      test_image_dataset: test_image_dataset
    }
  end

  @doc """
  Remove everything Kleene owns, except the `FreeBSD:testing` base image.

  Lives here rather than in `TestHelper` so that `Kleened.Test.ConnCase` -- which
  is compiled, unlike `test_helper.exs` -- can call it without a compile-time
  warning about an undefined module.

  Beyond the metadata-driven removal, the sweep is *convergent*: orphan datasets
  (created by a crashed run and no longer known to MetaData), leaked
  `kleene*`-interfaces, devfs/nullfs mounts under `kleene_root` and deferred
  snapshots on the basejail dataset are all reclaimed, so a failed run cannot
  poison the next one.
  """
  def cleanup() do
    stop_all_containers()
    MetaData.list_containers() |> Enum.map(fn %{id: id} -> Container.remove(id) end)

    # Orphan container datasets pin image datasets as clone origins; destroy
    # them before removing images so a single pass converges.
    sweep_orphan_datasets()

    MetaData.list_volumes() |> Enum.map(&Volume.remove(&1.name))

    MetaData.list_networks() |> Enum.map(fn %{id: id} -> Network.remove(id) end)

    MetaData.list_images()
    |> Enum.filter(fn image ->
      not (image.name == "FreeBSD" and image.tag == "testing")
    end)
    |> Enum.map(fn image -> Image.remove(image.id) end)

    sweep_basejail_snapshots()
    sweep_leaked_interfaces()
    sweep_leaked_mounts()
    :ok
  end

  defp stop_all_containers() do
    case Container.list(all: false) do
      [] ->
        :ok

      running_containers ->
        running_containers |> Enum.map(fn %{id: id} -> Container.stop(id) end)
        wait_for_containers_to_stop(50)
    end
  end

  # Jail teardown lags the synchronous stop response; poll actual liveness
  # instead of a fixed sleep, so a slow teardown no longer leaks the container
  # into the next test.
  defp wait_for_containers_to_stop(0) do
    :ok
  end

  defp wait_for_containers_to_stop(attempts_left) do
    case Container.list(all: false) do
      [] ->
        :ok

      running ->
        running |> Enum.map(fn %{id: id} -> Container.stop(id) end)
        :timer.sleep(100)
        wait_for_containers_to_stop(attempts_left - 1)
    end
  end

  # Datasets under kleene_root with no metadata row: residue from a crashed
  # create/remove. They keep image datasets pinned (clone origins), so they must
  # go before the image sweep can converge.
  defp sweep_orphan_datasets() do
    container_root = Config.get("container_root")
    image_root = Config.get("image_root")
    volume_root = Config.get("volume_root")

    known_datasets =
      (MetaData.list_containers() |> Enum.map(& &1.dataset)) ++
        (MetaData.list_image_datasets() |> Enum.map(& &1.dataset)) ++
        (MetaData.list_volumes() |> Enum.map(& &1.dataset))

    orphans =
      [container_root, image_root, volume_root]
      |> Enum.flat_map(&child_datasets/1)
      |> Enum.reject(&(&1 in known_datasets))

    Enum.map(orphans, fn dataset ->
      Logger.info("cleaning up orphan dataset #{dataset}")
      ZFS.destroy_force(dataset)
    end)
  end

  defp child_datasets(root) do
    {output, 0} = ZFS.cmd("list -H -r -o name #{root}")
    output |> String.split("\n") |> Enum.reject(&(&1 == "" or &1 == root))
  end

  # zfs-clone image creation snapshots the source dataset. With the origin
  # snapshot marked deferred the snapshot dies with its image, but snapshots
  # from runs predating that (or whose clone was force-destroyed) linger.
  # Anything on the basejail dataset without a live clone is garbage: the only
  # legitimate clone is a known image dataset, e.g. FreeBSD:testing.
  defp sweep_basejail_snapshots() do
    dataset = "zroot/kleene_basejail"

    if ZFS.exists?(dataset) do
      {output, 0} = ZFS.cmd("list -t snapshot -H -o name,clones -d 1 #{dataset}")

      snapshots =
        output
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&String.split(&1, "\t"))
        |> Enum.filter(fn [_name, clones] -> clones == "-" end)
        |> Enum.map(fn [snapshot, _clones] ->
          String.replace_prefix(snapshot, "#{dataset}@", "")
        end)

      case snapshots do
        [] ->
          :ok

        _ ->
          Logger.info("cleaning up #{length(snapshots)} basejail snapshots")

          # 'zfs destroy -d dataset@<snap>[,<snap>...]': one process for the
          # whole backlog, chunked to stay clear of ARG_MAX. '-d' keeps the
          # operation safe for snapshots whose clone appeared after listing.
          snapshots
          |> Enum.chunk_every(500)
          |> Enum.map(fn chunk ->
            snaps = Enum.join(chunk, ",")
            ZFS.cmd("destroy -d #{dataset}@#{snaps}", %{suppress_warning: true})
          end)
      end
    end
  end

  # Kleene interfaces are all named 'kleene<id>' (see Network's naming); any
  # such interface without a network row is residue from a crashed remove.
  defp sweep_leaked_interfaces() do
    known = MetaData.list_networks() |> Enum.map(& &1.interface) |> MapSet.new()

    {output, 0} = OS.cmd(~w"ifconfig -l")
    interface_list = output |> String.trim() |> String.split(" ")

    interface_list
    |> Enum.filter(&String.starts_with?(&1, "kleene"))
    |> Enum.reject(&(&1 in known))
    |> Enum.map(fn interface ->
      Logger.info("cleaning up leaked interface #{interface}")
      Network.destroy_interface(interface)
    end)
  end

  # devfs and nullfs mounts under kleene_root are left behind when a jail dies
  # without 'jail -r' teardown. ZFS mounts of the datasets themselves must be
  # left alone, hence the fstype filter and the trailing-slash prefix.
  defp sweep_leaked_mounts() do
    kleene_root = Config.get("kleene_root") <> "/"

    FreeBSD.mounts()
    |> Enum.filter(fn %{"node" => node, "fstype" => fstype} ->
      (fstype == "devfs" or fstype == "nullfs") and String.starts_with?(node, kleene_root)
    end)
    |> Enum.map(fn %{"node" => node} ->
      Logger.info("cleaning up leaked mount #{node}")
      OS.cmd(["/sbin/umount", "-f", node])
    end)
  end

  @doc """
  Assert that the host is back to the state captured by `get_host_state/0`.

  Run *after* `cleanup/0`, so what it catches is the residue cleanup cannot
  remove: a leaked jail, an interface that was never destroyed, a devfs mount
  left behind. Those would otherwise surface as an unrelated failure much later
  in the run.
  """
  def compare_to_baseline_environment(%{
        addresses: before_addresses,
        mount_devfs: before_mount_devfs
      }) do
    %{
      addresses: after_addresses,
      mount_devfs: after_mount_devfs,
      datasets: after_datasets
    } = get_host_state()

    %Schemas.Image{dataset: test_dataset} = MetaData.get_image("FreeBSD:testing")

    before_datasets =
      MapSet.new([
        test_dataset,
        "",
        "zroot/kleene",
        "zroot/kleene/container",
        "zroot/kleene/image",
        "zroot/kleene/volumes"
      ])

    assert before_addresses == after_addresses
    assert before_mount_devfs == after_mount_devfs

    assert before_datasets == after_datasets
  end

  defp list_host_addresses() do
    {output_json, 0} = OS.cmd(~w"netstat --libxo json -i")
    %{"statistics" => %{"interface" => addresses}} = Jason.decode!(output_json)
    addresses
  end

  defp get_kleene_devfs_mounts() do
    kleene_root = Config.get("kleene_root")
    {output_json, 0} = OS.cmd(~w"mount --libxo json -t devfs")
    %{"mount" => %{"mounted" => devfs_mounts}} = Jason.decode!(output_json)

    devfs_mounts
    |> Enum.map(fn %{"node" => mount_path} -> mount_path end)
    |> Enum.filter(&String.contains?(&1, kleene_root))
  end

  defp get_kleene_datasets() do
    {kleene_dataset, 0} = ZFS.cmd("list -H -r -o name zroot/kleene")
    kleene_dataset |> String.split("\n") |> MapSet.new()
  end

  defp process_image_creator_messages(creator_pid) do
    receive do
      {:image_creator, ^creator_pid, {:ok, image}} ->
        image

      {:image_creator, ^creator_pid, {:error, error_msg}} ->
        Logger.error("Could not build test base image: #{inspect(error_msg)}")
        Process.exit(self(), :failed_to_build_test_baseimage)
    end
  end
end
