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

  def exists?(dataset) do
    options = %{suppress_logging: true, suppress_warning: true}

    case OS.cmd(["/bin/sh", "-c", "zfs list -H -o name | grep #{dataset}"], options) do
      {_output, 0} -> true
      {_output, _nonzero_exit} -> false
    end
  end

  @spec info(String.t()) :: %{:exists? => boolean(), :mountpoint => String.t() | nil}
  def info(filesystem_or_snapshot) do
    options = %{suppress_logging: true, suppress_warning: true}

    case cmd("list -H -o mountpoint,origin #{filesystem_or_snapshot}", options) do
      {output, 0} ->
        [mountpoint, parent_snapshot] = parse_zfslist_line(output)

        mountpoint =
          case mountpoint == "none" do
            true -> nil
            false -> mountpoint
          end

        parent_snapshot =
          case parent_snapshot == "-" do
            true -> nil
            false -> parent_snapshot
          end

        %{:exists? => true, :mountpoint => mountpoint, parent_snapshot: parent_snapshot}

      {_, 1} ->
        %{:exists? => false, :mountpoint => nil, parent_snapshot: nil}
    end
  end

  defp parse_zfslist_line(line) do
    line = String.trim(line)
    String.split(line, "\t")
  end

  @spec cmd([String.t()]) :: {String.t(), integer()}
  def cmd(cmd, options \\ %{}) do
    OS.cmd(["/sbin/zfs" | String.split(cmd, " ")], options)
  end
end
