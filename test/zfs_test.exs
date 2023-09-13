defmodule ZFSTest do
  use ExUnit.Case
  require Logger

  alias Kleened.Core.Config
  alias Config
  import Kleened.Core.ZFS

  @moduletag :capture_log

  setup_all do
    start_supervised(Config)
    :ok
  end

  test "create clone test" do
    zroot_test = Config.get("zroot") <> "/create_clone_test"
    create(zroot_test)
    {_dataset, snapshot} = TestInitialization.test_base_dataset()
    assert {_, 0} = clone(snapshot, zroot_test <> "/zfs_test")
    assert {_, 0} = snapshot(zroot_test <> "/zfs_test@lol")
    assert {_, 0} = destroy(zroot_test <> "/zfs_test@lol")
    assert {_, 0} = destroy(zroot_test <> "/zfs_test")
    assert {_, 0} = destroy(zroot_test)
  end

  test "rename test" do
    zroot_test = Config.get("zroot") <> "/rename_test"
    zroot_test_new = Config.get("zroot") <> "/rename_test_newname"
    assert {_, 0} = create(zroot_test)
    assert {_, 0} = rename(zroot_test, zroot_test_new)
    assert {_, 0} = destroy(zroot_test_new)
  end
end
