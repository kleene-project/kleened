defmodule NetworkTest do
  use ExUnit.Case
  alias Jocker.Engine.Network
  alias Jocker.Engine.Config

  test "adding and removing ips from interface" do
    Application.stop(:jocker)
    {:ok, cfg_pid} = Config.start_link([])
    if_name = "jocker0"
    Config.put(:network_if_name, if_name)
    Config.put(:network_ip_start, "10.13.37.1")
    Config.put(:network_ip_end, "10.13.37.3")
    {:ok, pid} = Network.start_link([])
    assert Network.new() == "10.13.37.1"
    assert Network.new() == "10.13.37.2"

    assert ifconfig_check_if(if_name) ==
             {"\tinet 10.13.37.1 netmask 0xffffffff\n\tinet 10.13.37.2 netmask 0xffffffff\n", 0}

    :ok = Network.remove("10.13.37.1")
    :ok = Network.remove("10.13.37.2")

    assert ifconfig_check_if(if_name) == {"", 1}

    GenServer.stop(pid)
    GenServer.stop(cfg_pid)
  end

  test "generate new ips" do
    Application.stop(:jocker)
    {:ok, cfg_pid} = Config.start_link([])
    Config.put(:network_if_name, "jocker0")
    Config.put(:network_ip_start, "10.13.37.1")
    Config.put(:network_ip_end, "10.13.37.3")
    {:ok, pid} = Network.start_link([])
    assert Network.new() == "10.13.37.1"
    assert Network.new() == "10.13.37.2"
    assert Network.new() == "10.13.37.3"
    assert Network.new() == :out_of_ips
    GenServer.stop(pid)
    GenServer.stop(cfg_pid)
  end

  test "advanced generate new ips" do
    Application.stop(:jocker)
    {:ok, cfg_pid} = Config.start_link([])
    Config.put(:network_if_name, "jocker0")
    Config.put(:network_ip_start, "10.13.37.254")
    Config.put(:network_ip_end, "10.13.38.0")
    {:ok, pid} = Network.start_link([])
    assert Network.new() == "10.13.37.254"
    assert Network.new() == "10.13.37.255"
    assert Network.new() == "10.13.38.0"
    assert Network.new() == :out_of_ips
    GenServer.stop(pid)
    GenServer.stop(cfg_pid)
  end

  defp ifconfig_check_if(if_name) do
    System.cmd("/bin/sh", ["-c", "ifconfig #{if_name} | grep \"inet \""], stderr_to_stdout: true)
  end
end
