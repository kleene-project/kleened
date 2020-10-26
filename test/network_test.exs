defmodule NetworkTest do
  use ExUnit.Case
  alias Jocker.Engine.Network
  alias Jocker.Engine.Config

  test "adding and removing ips from interface" do
    Application.stop(:jocker)
    {:ok, cfg_pid} = Config.start_link([])
    if_name = "jocker0"
    Config.put("default_loopback_name", if_name)
    Config.put("default_subnet", "10.13.37.0/31")
    {:ok, pid} = Network.start_link([])
    assert Network.new() == "10.13.37.0"
    assert Network.new() == "10.13.37.1"

    assert Network.ip_added?("10.13.37.0")
    assert Network.ip_added?("10.13.37.1")

    :ok = Network.remove("10.13.37.0")
    :ok = Network.remove("10.13.37.1")

    assert ifconfig_check_if(if_name) == {"", 1}

    GenServer.stop(pid)
    GenServer.stop(cfg_pid)
  end

  test "running out of ips" do
    Application.stop(:jocker)
    {:ok, cfg_pid} = Config.start_link([])
    Config.put("default_loopback_name", "jocker0")
    Config.put("default_subnet", "10.13.37.0/31")
    {:ok, pid} = Network.start_link([])
    assert Network.new() == "10.13.37.0"
    assert Network.new() == "10.13.37.1"
    assert Network.new() == :out_of_ips
    GenServer.stop(pid)
    GenServer.stop(cfg_pid)
  end

  test "detection of default gateway" do
    # NOTE specific vm for my testing vm
    if_name = "em0"
    assert if_name == Network.detect_gateway_if()
    {:ok, _cfg_pid} = Config.start_link([])
    {:ok, _network_pid} = Network.start_link([])
    assert if_name == Config.get("default_gateway_if")
  end

  defp ifconfig_check_if(if_name) do
    System.cmd("/bin/sh", ["-c", "ifconfig #{if_name} | grep \"inet \""], stderr_to_stdout: true)
  end
end
