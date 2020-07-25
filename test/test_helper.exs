alias Jocker.Engine.ZFS
alias Jocker.Engine.Config
import Jocker.Engine.Records

ExUnit.start()

defmodule TestUtils do
  def now() do
    :timer.sleep(10)
    DateTime.to_iso8601(DateTime.utc_now())
  end

  def clear_zroot do
    ZFS.destroy_force(Config.get(:zroot))
    ZFS.create(Config.get(:zroot))
    ZFS.create(Config.get(:volume_root))
  end

  def devfs_mounted(container(layer_id: layer_id)) do
    layer(mountpoint: mountpoint) = Jocker.Engine.MetaData.get_layer(layer_id)
    devfs_path = Path.join(mountpoint, "dev")

    case System.cmd("sh", ["-c", "mount | grep \"devfs on #{devfs_path}\""]) do
      {"", 1} -> false
      {_output, 0} -> true
    end
  end
end
