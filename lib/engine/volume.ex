defmodule Jocker.Engine.Volume do
  alias Jocker.Engine.{ZFS, Config, Utils, Layer, MetaData, Container}
  require Config
  require Logger

  @derive Jason.Encoder
  defstruct([:name, :dataset, :mountpoint, :created])

  alias __MODULE__, as: Volume

  @type t() ::
          %Volume{
            name: String.t(),
            dataset: String.t(),
            mountpoint: String.t(),
            created: String.t()
          }

  defmodule Mount do
    @derive Jason.Encoder
    defstruct([:container_id, :volume_name, :location, read_only: false])

    @type t() ::
            %Mount{
              container_id: String.t(),
              volume_name: String.t(),
              location: String.t(),
              read_only: boolean()
            }
  end

  @type bind_opts() :: [
          rw: boolean()
        ]

  @spec create(String.t()) :: Volume.t()
  def create(name) do
    dataset = Path.join(Config.get("volume_root"), name)
    mountpoint = Path.join("/", dataset)
    ZFS.create(dataset)

    vol = %Volume{
      name: name,
      dataset: dataset,
      mountpoint: mountpoint,
      created: Utils.timestamp_now()
    }

    MetaData.add_volume(vol)
    Logger.debug("Volume created: #{inspect(vol)}")
    vol
  end

  @spec destroy(String.t()) :: :ok | {:error, String.t()}
  def destroy(name) do
    case Jocker.Engine.MetaData.get_volume(name) do
      :not_found ->
        {:error, "No such volume"}

      volume ->
        mounts = MetaData.remove_mounts(volume)
        Enum.map(mounts, fn %Mount{location: location} -> 0 = Utils.unmount(location) end)
        ZFS.destroy(volume.dataset)
        MetaData.remove_volume(volume)
        :ok
    end
  end

  @spec destroy_mounts(%Container{}) :: :ok
  def destroy_mounts(container) do
    mounts = MetaData.remove_mounts(container)
    Enum.map(mounts, fn %Mount{location: location} -> 0 = Utils.unmount(location) end)
  end

  @spec bind_volume(
          %Container{},
          Jocker.Engine.Records.volume(),
          String.t(),
          bind_opts()
        ) :: :ok
  def bind_volume(
        %Container{id: container_id, layer_id: layer_id},
        %Volume{name: volume_name, mountpoint: volume_mountpoint},
        location,
        opts \\ []
      ) do
    %Layer{mountpoint: container_mountpoint} = MetaData.get_layer(layer_id)
    absolute_location = Path.join(container_mountpoint, location)
    read_only = Keyword.get(opts, :ro, false)

    case read_only do
      false ->
        Utils.mount_nullfs([volume_mountpoint, absolute_location])

      true ->
        Utils.mount_nullfs(["-o", "ro", volume_mountpoint, absolute_location])
    end

    mnt = %Mount{
      container_id: container_id,
      volume_name: volume_name,
      location: absolute_location,
      read_only: read_only
    }

    MetaData.add_mount(mnt)
    :ok
  end
end
