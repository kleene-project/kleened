defmodule Jocker.Engine.Layer do
  use GenServer
  import Jocker.Engine.Records
  alias Jocker.Engine.Config

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def initialize(parent_layer) do
    GenServer.call(__MODULE__, {:initialize, parent_layer})
  end

  def finalize(layer) do
    GenServer.call(__MODULE__, {:finalize, layer})
  end

  @impl true
  def init([]) do
    {:ok, nil}
  end

  @impl true
  def handle_call({:initialize, parent_layer}, _from, nil) do
    new_layer = initialize_(parent_layer)
    {:reply, new_layer, nil}
  end

  @impl true
  def handle_call({:finalize, layer}, _from, nil) do
    updated_layer = finalize_(layer)
    {:reply, updated_layer, nil}
  end

  defp initialize_(layer(snapshot: parent_snapshot)) do
    id = Jocker.Engine.Utils.uuid()
    dataset = Path.join(Config.get(:zroot), id)
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

  defp finalize_(layer(dataset: dataset) = layer) do
    snapshot = dataset <> "@layer"
    0 = Jocker.Engine.ZFS.snapshot(snapshot)
    updated_layer = layer(layer, snapshot: snapshot)
    Jocker.Engine.MetaData.add_layer(updated_layer)
    updated_layer
  end
end
