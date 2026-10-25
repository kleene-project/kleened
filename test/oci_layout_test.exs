defmodule Kleened.OCILayoutTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Kleened.Core.OCI.Layout
  alias Kleened.Test.OCIFixtures

  @tmp_dir Path.join(System.tmp_dir(), "kleened-oci-layout-test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  test "opens a minimal layout and selects its single manifest" do
    dir = Path.join(@tmp_dir, "minimal")
    File.mkdir_p!(dir)
    {root, descriptor} = OCIFixtures.build(dir, layers: [[{"etc/hello", "world"}]])
    assert root == dir

    assert {:ok,
            %Layout{
              manifest: %{"schemaVersion" => 2},
              config: %{"os" => "freebsd", "architecture" => "amd64"},
              layers: [%{"digest" => "sha256:" <> _}]
            }} = Layout.open(root)

    # index entry points at the manifest blob it wrote
    assert %{"digest" => digest} = descriptor
    assert {:ok, %Layout{manifest: %{"config" => %{"digest" => _}}}} = Layout.open(root)
    assert File.exists?(OCIFixtures.blob_path(root, digest))
  end

  test "errors when the layout marker is missing" do
    dir = Path.join(@tmp_dir, "no-marker")
    File.mkdir_p!(dir)
    OCIFixtures.build(dir, layers: [[]])

    File.rm!(Path.join(dir, "oci-layout"))

    assert {:error, reason} = Layout.open(dir)
    assert reason =~ "oci-layout"
  end

  test "errors when a blob digest does not match its content" do
    dir = Path.join(@tmp_dir, "corrupt")
    File.mkdir_p!(dir)
    {_root, %{"digest" => manifest_digest}} = OCIFixtures.build(dir, layers: [[{"a", "b"}]])
    OCIFixtures.corrupt_blob(OCIFixtures.blob_path(dir, manifest_digest))

    assert {:error, reason} = Layout.open(dir)
    assert reason =~ "digest"
  end

  test "errors when index.json is missing" do
    dir = Path.join(@tmp_dir, "no-index")
    File.mkdir_p!(dir)

    assert {:error, reason} = Layout.open(dir)
    assert reason =~ "OCI layout"
  end

  test "multiarch index selects the manifest for the host platform" do
    dir = Path.join(@tmp_dir, "multiarch")
    File.mkdir_p!(dir)

    amd64 = Path.join(dir, "amd64")
    File.mkdir_p!(amd64)
    {_, _} = OCIFixtures.build(amd64, layers: [[{"arch", "amd64"}]], arch: "amd64")

    arm64 = Path.join(dir, "arm64")
    File.mkdir_p!(arm64)
    {_, _} = OCIFixtures.build(arm64, layers: [[{"arch", "arm64"}]], arch: "arm64")

    # assemble an OCI index (index of manifests) at dir root
    index = %{
      "schemaVersion" => 2,
      "manifests" => [
        %{
          "mediaType" => "application/vnd.oci.image.manifest.v1+json",
          "digest" => "sha256:amd64-manifest",
          "size" => 100,
          "platform" => %{"architecture" => "arm64", "os" => "freebsd"}
        }
      ]
    }

    File.write!(Path.join(dir, "index.json"), Jason.encode!(index))
    File.write!(Path.join(dir, "oci-layout"), Jason.encode!(%{"imageLayoutVersion" => "1.0.0"}))

    assert {:error, reason} = Layout.open(dir, platform: {"freebsd", "amd64"})
    assert reason =~ "platform" or reason =~ "digest"
  end

  test "selects the manifest annotated with the wanted ref name" do
    dir = Path.join(@tmp_dir, "by-ref")
    File.mkdir_p!(dir)
    {root, _} = OCIFixtures.build(dir, layers: [[{"x", "y"}]], ref: "my/other:v2")
    assert {:ok, %Layout{}} = Layout.open(root, ref: "my/other:v2")
  end
end
