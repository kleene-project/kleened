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
        Logger.warn(
          "could not understand the output from 'sysctl' when inspecting ip forwarding configuration"
        )
    end

    :ok
  end

  def create_epair() do
    case OS.cmd(~w"/sbin/ifconfig epair create") do
      {epair_a_raw, 0} ->
        String.slice(epair_a_raw, 0, String.length(epair_a_raw) - 2)

      {error_msg, _nonzero} ->
        Logger.warn("could not create anew epair, ifconfig failed with: #{error_msg}")
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
        Logger.warn(
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
        Logger.warn("could not remove interface #{epair}a from bridge: #{error_msg}")
    end

    case OS.cmd(~w"ifconfig #{epair}a destroy") do
      {_, 0} ->
        :ok

      {error_msg, _exitcode} ->
        Logger.warn("could not destroy #{epair}b: #{error_msg}")
        {:error, error_msg}
    end
  end
end
