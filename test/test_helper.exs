alias Jocker.Engine.ZFS
alias Jocker.Engine.Config

ExUnit.start()

defmodule TestUtils do
  def clear_zroot do
    ZFS.destroy_force(Config.get(:zroot))
    ZFS.create(Config.get(:zroot))
    ZFS.create(Config.get(:volume_root))
  end
end
