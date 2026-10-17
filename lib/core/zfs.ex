defmodule Kleened.Core.ZFS do
  require Logger
  alias Kleened.Core.OS

  @typedoc "A ZFS dataset name, e.g. `zroot/kleene/container/<id>`."
  @type dataset() :: String.t()

  @typedoc "A ZFS snapshot name, e.g. `zroot/kleene/image/<id>@image`."
  @type snapshot() :: String.t()

  @spec create(dataset()) :: OS.cmd_result()
  def create(dataset) do
    # zfs create [-pu] [-o property=value]... filesystem
    cmd("create #{dataset}")
  end

  @spec destroy(dataset() | snapshot()) :: OS.cmd_result()
  def destroy(dataset) do
    # zfs destroy [-dnpRrv] snapshot[%snapname][,...]
    # zfs destroy [-fnpRrv] filesystem|volume
    cmd("destroy -f #{dataset}")
  end

  @spec destroy_force(dataset() | snapshot()) :: OS.cmd_result()
  def destroy_force(dataset) do
    cmd("destroy -rf #{dataset}")
  end

  @spec snapshot(snapshot()) :: OS.cmd_result()
  def snapshot(name) do
    # zfs snapshot|snap [-r] [-o property=value]
    cmd("snapshot #{name}")
  end

  @spec clone(snapshot(), dataset()) :: OS.cmd_result()
  def clone(snapshot, clonename) do
    cmd("clone #{snapshot} #{clonename}")
  end

  @spec rename(dataset(), dataset()) :: OS.cmd_result()
  def rename(dataset, new_dataset) do
    cmd("rename -f #{dataset} #{new_dataset}")
  end

  @spec mountpoint(dataset()) :: String.t()
  def mountpoint(dataset) do
    case info(dataset) do
      %{mountpoint: nil} ->
        Logger.warning("No mountpoint found for dataset '#{dataset}'")
        ""

      %{mountpoint: mountpoint} ->
        mountpoint
    end
  end

  @spec exists?(dataset()) :: boolean()
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

  @spec info(dataset() | snapshot()) :: %{exists?: boolean(), mountpoint: String.t() | nil}
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

  @spec parse_zfslist_line(String.t()) :: [String.t()]
  defp parse_zfslist_line(line) do
    line = String.trim(line)
    String.split(line, "\t")
  end

  @spec cmd(String.t(), OS.cmd_options()) :: OS.cmd_result()
  def cmd(cmd, options \\ %{}) do
    OS.cmd(["/sbin/zfs" | String.split(cmd, " ")], options)
  end
end
