alias Jocker.Engine.ZFS
alias Jocker.Engine.Config
import Jocker.Engine.Records

ExUnit.start()

ExUnit.configure(
  seed: 0,
  trace: true,
  max_failures: 1
)

defmodule TestHelper do
  def now() do
    :timer.sleep(10)
    DateTime.to_iso8601(DateTime.utc_now())
  end

  def collect_container_output(id) do
    output = collect_container_output_(id, [])
    output |> Enum.reverse() |> Enum.join("")
  end

  defp collect_container_output_(id, output) do
    receive do
      {:container, ^id, {:shutdown, :jail_stopped}} ->
        output

      {:container, ^id, msg} ->
        collect_container_output_(id, [msg | output])

      unknown ->
        IO.puts(
          "\nUnknown message received while collecting container output: #{inspect(unknown)}"
        )
    end
  end

  def clear_zroot() do
    {:ok, _pid} = Config.start_link([])
    zroot = Config.get("zroot")
    Agent.stop(Config)
    ZFS.destroy_force(zroot)
    ZFS.create(zroot)
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
