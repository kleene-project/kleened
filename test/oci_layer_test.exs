defmodule Kleened.OCILayerTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Kleened.Core.OCI.Layer
  alias Kleened.Test.OCIFixtures

  @tmp_dir Path.join(System.tmp_dir(), "kleened-oci-layer-test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp layer_blob(name, entries) do
    dir = Path.join(@tmp_dir, "layers-#{name}")
    File.mkdir_p!(dir)
    {_dir, %{"digest" => manifest_digest}} = OCIFixtures.build(dir, layers: [entries])
    manifest_path = OCIFixtures.blob_path(dir, manifest_digest)
    {:ok, manifest} = manifest_path |> File.read!() |> Jason.decode()
    OCIFixtures.blob_path(dir, manifest["layers"] |> hd() |> Map.fetch!("digest"))
  end

  defp apply!(blob, dest) do
    assert :ok = Layer.apply(blob, dest)
  end

  test "applies a layer, content is readable" do
    blob = layer_blob("minimal", [{"etc/hello", "world"}])
    dest = Path.join(@tmp_dir, "dest-minimal")
    File.mkdir_p!(dest)

    apply!(blob, dest)
    assert File.read!(Path.join(dest, "etc/hello")) == "world"
  end

  test "whiteout removes the lower file and leaves no whiteout artifact" do
    lower = layer_blob("lower", [{"a/keep", "1"}, {"a/gone", "2"}])
    upper = layer_blob("upper", [{"a/.wh.gone", ""}])
    dest = Path.join(@tmp_dir, "dest-whiteout")
    File.mkdir_p!(dest)

    apply!(lower, dest)
    assert File.exists?(Path.join(dest, "a/gone"))
    apply!(upper, dest)

    assert File.exists?(Path.join(dest, "a/keep"))
    refute File.exists?(Path.join(dest, "a/gone"))
    refute File.exists?(Path.join(dest, "a/.wh.gone"))
  end

  test "opaque marker clears the directory before the layer's own files land" do
    lower = layer_blob("lower-opq", [{"b/doomed-old", "1"}, {"b/doomed", "2"}])
    upper = layer_blob("upper-opq", [{"b/.wh..wh..opq", ""}, {"b/new", "3"}])
    dest = Path.join(@tmp_dir, "dest-opaque")
    File.mkdir_p!(dest)

    apply!(lower, dest)
    apply!(upper, dest)

    refute File.exists?(Path.join(dest, "b/doomed-old"))
    refute File.exists?(Path.join(dest, "b/doomed"))
    assert File.exists?(Path.join(dest, "b/new"))
    refute File.exists?(Path.join(dest, "b/.wh..wh..opq"))
  end

  test "layers apply associatively: sequence order does not matter" do
    # Applying layers in sequence gives the same result regardless of destination.
    l1 = layer_blob("assoc-1", [{"x", "1"}])
    l2 = layer_blob("assoc-2", [{"y", "2"}])
    dest_one = Path.join(@tmp_dir, "dest-one")
    dest_two = Path.join(@tmp_dir, "dest-two")
    File.mkdir_p!(dest_one)
    File.mkdir_p!(dest_two)

    apply!(l1, dest_one)
    apply!(l2, dest_one)

    apply!(l1, dest_two)
    apply!(l2, dest_two)

    assert File.read!(Path.join(dest_one, "x")) == "1"
    assert File.read!(Path.join(dest_one, "y")) == "2"
    assert File.read!(Path.join(dest_two, "x")) == File.read!(Path.join(dest_one, "x"))
    assert File.read!(Path.join(dest_two, "y")) == File.read!(Path.join(dest_one, "y"))
  end

  test "symlinks and file modes are preserved, including relative symlinks escaping dest" do
    blob =
      layer_blob("meta", [
        {"bin/ld", {:symlink, "../../libexec/ld-elf.so.1"}},
        {"secret", {"inner", 0o700}}
      ])

    dest = Path.join(@tmp_dir, "dest-meta")
    File.mkdir_p!(dest)

    apply!(blob, dest)

    assert File.read_link!(Path.join(dest, "bin/ld")) == "../../libexec/ld-elf.so.1"
    # stat/1 mode includes the file-type bits; mask to the permission bits.
    assert 0o700 == Bitwise.band(File.stat!(Path.join(dest, "secret")).mode, 0o777)
  end

  test "hardlinks are preserved" do
    blob =
      layer_blob("hardlink", [
        {"a/file", "content"},
        {"b/link", {:hardlink, "a/file"}}
      ])

    dest = Path.join(@tmp_dir, "dest-hardlink")
    File.mkdir_p!(dest)

    apply!(blob, dest)
    assert File.read!(Path.join(dest, "b/link")) == "content"
  end

  test "error path: corrupt layer blob" do
    blob = layer_blob("corrupt", [{"a", "b"}])
    File.write!(blob, "this is not a tar")
    dest = Path.join(@tmp_dir, "dest-corrupt")
    File.mkdir_p!(dest)

    assert {:error, reason} = Layer.apply(blob, dest)
    assert is_binary(reason)
  end
end
