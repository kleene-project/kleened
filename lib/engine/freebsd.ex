defmodule Jocker.Engine.FreeBSD do
  alias Jocker.Engine.OS
  require Logger

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
