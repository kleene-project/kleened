defmodule NetworkTest do
  use ExUnit.Case

  test "generate new ips" do
    Application.stop(:jocker)
    range = {"10.13.37.1", "10.13.37.3"}
    if_name = "jocker0"
    {:ok, pid} = Jocker.Network.start_link([range, if_name])
    assert Jocker.Network.new() == "10.13.37.1"
    assert Jocker.Network.new() == "10.13.37.2"
    assert Jocker.Network.new() == "10.13.37.3"
    assert Jocker.Network.new() == :out_of_ips
    GenServer.stop(pid)
  end

  test "advanced generate new ips" do
    Application.stop(:jocker)
    range = {"10.13.37.254", "10.13.38.0"}
    if_name = "jocker0"
    {:ok, pid} = Jocker.Network.start_link([range, if_name])
    assert Jocker.Network.new() == "10.13.37.254"
    assert Jocker.Network.new() == "10.13.37.255"
    assert Jocker.Network.new() == "10.13.38.0"
    assert Jocker.Network.new() == :out_of_ips
    GenServer.stop(pid)
  end
end
