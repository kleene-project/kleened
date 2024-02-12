defmodule ZFSTest do
  use ExUnit.Case
  require Logger

  alias Kleened.Core.{Const, Config, MetaData}
  import Kleened.Core.ZFS

  @moduletag :capture_log

  setup_all do
    start_supervised(Config)
    :ok
  end

  test "create clone test" do
    zroot_test = Config.get("kleene_root") <> "/create_clone_test"
    create(zroot_test)
    image = MetaData.get_image("FreeBSD:testing")

    assert {_, 0} = clone(image.dataset <> Const.image_snapshot(), zroot_test <> "/zfs_test")
    assert {_, 0} = snapshot(zroot_test <> "/zfs_test@lol")
    assert {_, 0} = destroy(zroot_test <> "/zfs_test@lol")
    assert {_, 0} = destroy(zroot_test <> "/zfs_test")
    assert {_, 0} = destroy(zroot_test)
  end

  test "rename test" do
    zroot_test = Config.get("kleene_root") <> "/rename_test"
    zroot_test_new = Config.get("kleene_root") <> "/rename_test_newname"
    assert {_, 0} = create(zroot_test)
    assert {_, 0} = rename(zroot_test, zroot_test_new)
    assert {_, 0} = destroy(zroot_test_new)
  end
end
