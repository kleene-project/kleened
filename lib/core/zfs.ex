defmodule Kleened.Core.ZFS do
  require Logger
  alias Kleened.Core.OS

  @spec create(String.t()) :: {String.t(), integer()}
  def create(dataset) do
    # zfs create [-pu] [-o property=value]... filesystem
    cmd("create #{dataset}")
  end

  @spec destroy(String.t()) :: {String.t(), integer()}
  def destroy(dataset) do
    # zfs destroy [-dnpRrv] snapshot[%snapname][,...]
    # zfs destroy [-fnpRrv] filesystem|volume
    cmd("destroy -f #{dataset}")
  end

  @spec destroy_force(String.t()) :: {String.t(), integer()}
  def destroy_force(dataset) do
    cmd("destroy -rf #{dataset}")
  end

  @spec snapshot(String.t()) :: {String.t(), integer()}
  def snapshot(name) do
    # zfs snapshot|snap [-r] [-o property=value]
    cmd("snapshot #{name}")
  end

  @spec clone(String.t(), String.t()) :: {String.t(), integer()}
  def clone(snapshot, clonename) do
    cmd("clone #{snapshot} #{clonename}")
  end

  @spec rename(String.t(), String.t()) :: {String.t(), integer()}
  def rename(dataset, new_dataset) do
    cmd("rename -f #{dataset} #{new_dataset}")
  end

  @spec mountpoint(String.t()) :: String.t() | nil
  def mountpoint(dataset) do
    case info(dataset) do
      %{mountpoint: nil} ->
        Logger.warning("No mountpoint found for dataset '#{dataset}'")
        ""

      %{mountpoint: mountpoint} ->
        mountpoint
    end
  end

  def exists?(<<"/", _::binary>>) do
    false
  end

  def exists?(dataset) do
    options = %{suppress_logging: true, suppress_warning: true}

    case OS.cmd(["/bin/sh", "-c", "zfs list -H -o name #{dataset}"], options) do
      {_output, 0} -> true
      {_output, _nonzero_exit} -> false
    end
  end

  @spec info(String.t()) :: %{:exists? => boolean(), :mountpoint => String.t() | nil}
  def info(filesystem_or_snapshot) do
    options = %{suppress_logging: true, suppress_warning: true}

    case cmd("list -H -o mountpoint #{filesystem_or_snapshot}", options) do
      {"none\n", 0} ->
        %{:exists? => true, :mountpoint => nil}

      {mountpoint_n, 0} ->
        mountpoint = String.trim(mountpoint_n)
        %{:exists? => true, :mountpoint => mountpoint}

      {_, 1} ->
        %{:exists? => false, :mountpoint => nil}
    end
  end

  @spec cmd([String.t()]) :: {String.t(), integer()}
  def cmd(cmd, options \\ %{}) do
    OS.cmd(["/sbin/zfs" | String.split(cmd, " ")], options)
  end
end
