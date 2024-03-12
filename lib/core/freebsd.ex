defmodule Kleened.Core.FreeBSD do
  alias Kleened.Core.OS
  require Logger

  @spec enable_ip_forwarding() :: :ok
  def enable_ip_forwarding() do
    case OS.cmd(~w"/sbin/sysctl net.inet.ip.forwarding") do
      {"net.inet.ip.forwarding: 1\n", _} ->
        :ok

      {"net.inet.ip.forwarding: 0\n", _} ->
        OS.cmd(~w"/sbin/sysctl net.inet.ip.forwarding=1")

      {_unknown_output, _exitcode} ->
        Logger.warning(
          "could not understand the output from 'sysctl' when inspecting ip forwarding configuration"
        )
    end

    :ok
  end

  def get_interface_addresses(interface_name) do
    {output_json, 0} = OS.cmd(~w"/usr/bin/netstat --libxo json -I #{interface_name}")
    %{"statistics" => %{"interface" => addresses}} = Jason.decode!(output_json)
    addresses
  end

  def create_epair() do
    case OS.cmd(~w"/sbin/ifconfig epair create") do
      {epair_a_raw, 0} ->
        String.slice(epair_a_raw, 0, String.length(epair_a_raw) - 2)

      {error_msg, _nonzero} ->
        Logger.warning("could not create anew epair, ifconfig failed with: #{error_msg}")
        nil
    end
  end

  @spec(
    destroy_bridged_vnet_epair(String.t(), String.t(), String.t()) :: :ok,
    {:error, String.t()}
  )
  def destroy_bridged_vnet_epair(epair, bridge, container_id) do
    case OS.cmd(~w"/sbin/ifconfig #{epair}b -vnet #{container_id}") do
      {_, 0} ->
        destroy_bridged_epair(epair, bridge)

      {error_msg, _exitcode} ->
        Logger.warning(
          "could not reclaim interface #{epair}b from jail #{container_id}: #{error_msg}"
        )

        {:error, error_msg}
    end
  end

  @spec(
    destroy_bridged_epair(String.t(), String.t()) :: :ok,
    {:error, String.t()}
  )
  def destroy_bridged_epair(epair, bridge) do
    case OS.cmd(~w"ifconfig #{bridge} deletem #{epair}a") do
      {_, 0} ->
        :ok

      {error_msg, _exitcode} ->
        Logger.warning("could not remove interface #{epair}a from bridge: #{error_msg}")
    end

    case OS.cmd(~w"ifconfig #{epair}a destroy") do
      {_, 0} ->
        :ok

      {error_msg, _exitcode} ->
        Logger.warning("could not destroy #{epair}b: #{error_msg}")
        {:error, error_msg}
    end
  end

  def clear_devfs(mountpoint) do
    devfs_mountpoint = "#{mountpoint}/dev"
    {output_json, 0} = OS.cmd(~w"mount --libxo json -t devfs")
    %{"mount" => %{"mounted" => devfs_mounts}} = Jason.decode!(output_json)

    devfs_mounts
    |> Enum.map(fn %{"node" => devfs_mountpoint} -> devfs_mountpoint end)
    |> Enum.filter(&(devfs_mountpoint == &1))
    |> Enum.map(&OS.cmd(["/sbin/umount", &1]))
  end

  def running_jails() do
    {jails_json, 0} = System.cmd("jls", ["-v", "--libxo=json"], stderr_to_stdout: true)
    {:ok, jails} = Jason.decode(jails_json)
    Enum.map(jails["jail-information"]["jail"], &{&1["name"], &1["jid"]})
  end
end
