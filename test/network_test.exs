defmodule NetworkTest do
  use ExUnit.Case
  alias Jocker.Engine.Network

  test "generate new ips" do
    Application.stop(:jocker)
    range = {"10.13.37.1", "10.13.37.3"}
    if_name = "jocker0"
    {:ok, pid} = Network.start_link([range, if_name])
    assert Network.new() == "10.13.37.1"
    assert Network.new() == "10.13.37.2"
    assert Network.new() == "10.13.37.3"
    assert Network.new() == :out_of_ips
    GenServer.stop(pid)
  end

  test "advanced generate new ips" do
    Application.stop(:jocker)
    range = {"10.13.37.254", "10.13.38.0"}
    if_name = "jocker0"
    {:ok, pid} = Network.start_link([range, if_name])
    assert Network.new() == "10.13.37.254"
    assert Network.new() == "10.13.37.255"
    assert Network.new() == "10.13.38.0"
    assert Network.new() == :out_of_ips
    GenServer.stop(pid)
  end
end
