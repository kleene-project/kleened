defmodule JockerTest do
  use ExUnit.Case
  doctest Jocker

  test "greets the world" do
    assert Jocker.hello() == :world
  end
end
