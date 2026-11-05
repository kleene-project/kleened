defmodule JailTest do
  use ExUnit.Case
  alias Kleened.API.Schemas

  @moduletag :capture_log
  # Pure function: no jails, ZFS, pf or daemon. Part of the fast 'unit' tier.
  @moduletag :unit

  describe "default_hostname/2" do
    test "an ordinary container name is the default hostname" do
      assert Kleened.Core.Jail.default_hostname("abc123", "web") == "web"
    end

    test "a dotted name is a legal hostname and kept" do
      assert Kleened.Core.Jail.default_hostname("abc123", "my.app") == "my.app"
    end

    test "an empty name falls back to the id" do
      assert Kleened.Core.Jail.default_hostname("abc123", "") == "abc123"
    end

    test "a nil name falls back to the id" do
      assert Kleened.Core.Jail.default_hostname("abc123", nil) == "abc123"
    end
  end
end
