defmodule Jocker.Engine.Layer do
  use GenServer
  import Jocker.Engine.Records
  alias Jocker.Engine.Config

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def new(parent_layer, container_id) do
    GenServer.call(__MODULE__, {:new, parent_layer, container_id})
  end

  def to_image(layer, image_id) do
    GenServer.call(__MODULE__, {:to_image, layer, image_id})
  end

  @impl true
  def init([]) do
    {:ok, nil}
  end

  @impl true
  def handle_call({:new, parent_layer, container_id}, _from, nil) do
    new_layer = new_(parent_layer, container_id)
    {:reply, new_layer, nil}
  end

  @impl true
  def handle_call({:to_image, layer, image_id}, _from, nil) do
    updated_layer = to_image_(layer, image_id)
    {:reply, updated_layer, nil}
  end

  defp new_(layer(snapshot: parent_snapshot), container_id) do
    id = Jocker.Engine.Utils.uuid()
    dataset = Path.join([Config.get("zroot"), "container", container_id])
    0 = Jocker.Engine.ZFS.clone(parent_snapshot, dataset)

    new_layer =
      layer(
        id: id,
        dataset: dataset,
        mountpoint: Path.join("/", dataset)
      )

    Jocker.Engine.MetaData.add_layer(new_layer)
    new_layer
  end

  defp to_image_(layer(dataset: dataset) = layer, image_id) do
    new_dataset = Path.join([Config.get("zroot"), "image", image_id])
    Jocker.Engine.ZFS.rename(dataset, new_dataset)

    snapshot = new_dataset <> "@layer"
    mountpoint = "/" <> new_dataset
    0 = Jocker.Engine.ZFS.snapshot(snapshot)
    updated_layer = layer(layer, snapshot: snapshot, dataset: new_dataset, mountpoint: mountpoint)
    Jocker.Engine.MetaData.add_layer(updated_layer)
    updated_layer
  end
end
