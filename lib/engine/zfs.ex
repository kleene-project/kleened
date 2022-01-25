defmodule Jocker.Engine.ZFS do
  require Logger

  @spec create(String.t()) :: integer()
  def create(dataset) do
    # zfs create [-pu] [-o property=value]... filesystem
    cmd(["create", dataset])
  end

  @spec destroy(String.t()) :: integer()
  def destroy(dataset) do
    # zfs destroy [-dnpRrv] snapshot[%snapname][,...]
    # zfs destroy [-fnpRrv] filesystem|volume
    cmd(["destroy", dataset])
  end

  @spec destroy_force(String.t()) :: integer()
  def destroy_force(dataset) do
    cmd(["destroy", "-rf", dataset])
  end

  @spec snapshot(String.t()) :: integer()
  def snapshot(name) do
    # zfs snapshot|snap [-r] [-o property=value]
    cmd(["snapshot", name])
  end

  @spec clone(String.t(), String.t()) :: integer()
  def clone(snapshot, clonename) do
    cmd(["clone", snapshot, clonename])
  end

  @spec rename(String.t(), String.t()) :: integer()
  def rename(dataset, new_dataset) do
    cmd(["rename", dataset, new_dataset])
  end

  @spec info(String.t()) :: %{:exists? => boolean(), :mountpoint => String.t() | nil}
  def info(filesystem_or_snapshot) do
    case System.cmd("zfs", ["list", "-H", "-o", "mountpoint", filesystem_or_snapshot]) do
      {"none\n", 0} ->
        %{:exists? => true, :mountpoint => nil}

      {mountpoint_n, 0} ->
        mountpoint = String.trim(mountpoint_n)
        %{:exists? => true, :mountpoint => mountpoint}

      {_, 1} ->
        %{:exists? => false, :mountpoint => nil}
    end
  end

  @spec cmd([String.t()]) :: integer()
  def cmd(cmd) do
    {stdout, exit_code} = System.cmd("/sbin/zfs", cmd, stderr_to_stdout: true)

    Logger.debug(
      "'zfs #{Enum.join(cmd, " ")}' exited with code #{exit_code} and reason: #{stdout}"
    )

    exit_code
  end
end
