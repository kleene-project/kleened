defmodule Kleened.Test.Utils do
  alias Kleened.Core.{Config, MetaData, Container, Image, ImageCreate, OS, ZFS}
  alias Kleened.API.Schemas
  require Logger

  @creation_time "2023-09-14T21:21:57.990515Z"
  def create_test_base_image() do
    creator_pid =
      ImageCreate.start_image_creation(%Schemas.ImageCreateConfig{
        method: "zfs-clone",
        tag: "FreeBSD:testing",
        zfs_dataset: "zroot/kleene_basejail"
      })

    image = process_image_creator_messages(creator_pid)
    MetaData.add_image(%Schemas.Image{image | created: @creation_time})
    :ok
  end

  def clear() do
    MetaData.list_containers() |> Enum.map(fn %{id: id} -> Container.remove(id) end)

    MetaData.list_images()
    |> Enum.filter(fn %Schemas.Image{id: id} -> id != "base" end)
    |> Enum.map(fn %Schemas.Image{id: id} -> Image.remove(id) end)
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
