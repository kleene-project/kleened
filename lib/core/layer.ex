defmodule Kleened.Core.Layer do
  use GenServer
  alias Kleened.Core.{Config, MetaData}
  require Logger

  @derive Jason.Encoder
  defstruct id: "",
            parent_id: "",
            dataset: "",
            snapshot: "",
            mountpoint: ""

  alias __MODULE__, as: Layer

  @type t() :: %Layer{
          id: String.t(),
          parent_id: String.t(),
          dataset: String.t(),
          snapshot: String.t(),
          mountpoint: String.t()
        }

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def new(parent_layer, container_id) do
    GenServer.call(__MODULE__, {:new, parent_layer, container_id})
  end

  def to_image_from_layer(layer, image_id) do
    GenServer.call(__MODULE__, {:to_image_from_layer, layer, image_id})
  end

  def destroy(layer_id) do
    GenServer.call(__MODULE__, {:destroy, layer_id})
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

  def handle_call({:destroy, layer_id}, _from, nil) do
    destroy_(layer_id)
    {:reply, :ok, nil}
  end

  def handle_call({:to_image_from_layer, layer, image_id}, _from, nil) do
    updated_layer = to_image_from_layer_(layer, image_id)
    {:reply, updated_layer, nil}
  end

  defp new_(%Layer{snapshot: parent_snapshot}, container_id) do
    dataset = Path.join([Config.get("zroot"), "container", container_id])
    {_, 0} = Kleened.Core.ZFS.clone(parent_snapshot, dataset)

    new_layer = %Layer{
      id: Kleened.Core.Utils.uuid(),
      dataset: dataset,
      mountpoint: Path.join("/", dataset)
    }

    Kleened.Core.MetaData.add_layer(new_layer)
    new_layer
  end

  defp destroy_(layer_id) do
    case MetaData.get_layer(layer_id) do
      %Layer{dataset: dataset} ->
        {_, 0} = Kleened.Core.ZFS.destroy(dataset)
        MetaData.remove_layer(layer_id)

      :not_found ->
        Logger.warn("layer with id #{layer_id} could not be found.")
    end
  end

  defp to_image_from_layer_(%Layer{dataset: dataset} = layer, image_id) do
    new_dataset = Path.join([Config.get("zroot"), "image", image_id])
    Kleened.Core.ZFS.rename(dataset, new_dataset)

    snapshot = new_dataset <> "@layer"
    mountpoint = "/" <> new_dataset
    {_, 0} = Kleened.Core.ZFS.snapshot(snapshot)

    updated_layer = %Layer{
      layer
      | snapshot: snapshot,
        dataset: new_dataset,
        mountpoint: mountpoint
    }

    Kleened.Core.MetaData.add_layer(updated_layer)
    updated_layer
  end
end
