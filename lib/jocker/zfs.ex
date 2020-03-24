defmodule Jocker.ZFS do
  import Jocker.Config

  def clear_zroot do
    destroy_force(zroot())
    create(zroot())
    :ok
  end

  def create(dataset) do
    # zfs create [-pu] [-o property=value]... filesystem
    cmd(["create", dataset])
  end

  def destroy(dataset) do
    # zfs destroy [-dnpRrv] snapshot[%snapname][,...]
    # zfs destroy [-fnpRrv] filesystem|volume
    cmd(["destroy", dataset])
  end

  def destroy_force(dataset) do
    cmd(["destroy", "-rf", dataset])
  end

  def snapshot(name) do
    # zfs snapshot|snap [-r] [-o property=value]
    cmd(["snapshot", name])
  end

  def clone(snapshot, clonename) do
    cmd(["clone", snapshot, clonename])
  end

  def rename(dataset, new_dataset) do
    cmd(["rename", dataset, new_dataset])
  end

  def cmd(cmd) do
   {_stdout, exit_code} = System.cmd("/sbin/zfs", cmd)
    exit_code
  end
end
