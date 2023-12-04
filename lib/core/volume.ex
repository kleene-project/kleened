defmodule Kleened.Core.Volume do
  alias Kleened.Core.{ZFS, Config, Utils, Mount, MetaData}
  alias Kleened.API.Schemas
  require Config
  require Logger

  alias __MODULE__, as: Volume

  @type t() :: %Schemas.Volume{}

  @spec create(String.t()) :: Volume.t()
  def create(name) do
    case MetaData.get_volume(name) do
      :not_found ->
        dataset = Path.join(Config.get("volume_root"), name)
        mountpoint = Path.join("/", dataset)
        ZFS.create(dataset)

        volume = %Schemas.Volume{
          name: name,
          dataset: dataset,
          mountpoint: mountpoint,
          created: Utils.timestamp_now()
        }

        MetaData.add_volume(volume)
        Logger.debug("Volume created: #{inspect(volume)}")
        volume

      %Schemas.Volume{} = volume ->
        volume
    end
  end

  @spec destroy(String.t()) :: :ok | {:error, String.t()}
  def destroy(name) do
    destroy_(name)
  end

  @spec prune() :: {:ok, [String.t()]}
  def prune() do
    pruned_volumes =
      MetaData.list_unused_volumes()
      |> Enum.map(fn keywords ->
        volume_name = Keyword.get(keywords, :name)
        destroy_(volume_name)
        volume_name
      end)

    {:ok, pruned_volumes}
  end

  @spec inspect_(String.t()) :: {:ok, %Schemas.VolumeInspect{}} | {:error, String.t()}
  def inspect_(name) do
    case MetaData.get_volume(name) do
      :not_found ->
        {:error, "No such volume"}

      volume ->
        mounts = MetaData.list_mounts(volume)
        {:ok, %Schemas.VolumeInspect{volume: volume, mountpoints: mounts}}
    end
  end

  defp destroy_(name) do
    case Kleened.Core.MetaData.get_volume(name) do
      :not_found ->
        {:error, "No such volume"}

      volume ->
        Mount.remove_mounts(volume)
        ZFS.destroy(volume.dataset)
        MetaData.remove_volume(volume)
        :ok
    end
  end
end
