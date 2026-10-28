defmodule Kleened.RegistryTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Kleened.Core.Registry
  alias Kleened.Test.{OCIFixtures, RegistryDouble}

  @tmp_dir Path.join(System.tmp_dir(), "kleened-registry-test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)

    layout_dir = Path.join(@tmp_dir, "layout")
    File.mkdir_p!(layout_dir)
    {root, _descriptor} = OCIFixtures.build(layout_dir, layers: [[{"etc/hello", "world"}]])
    %{layout_dir: root}
  end

  test "pull fetches the manifest, config and layers, verifying digests", %{layout_dir: root} do
    {:ok, listener, port} = RegistryDouble.start(root)
    on_exit(fn -> RegistryDouble.stop(listener) end)

    assert {:ok, %{root: download_dir}} =
             Registry.pull("127.0.0.1:#{port}/test/minimal:latest",
               base_url: "http://127.0.0.1:#{port}"
             )

    # the downloaded set is an on-disk OCI layout Layout.open can consume
    assert {:ok, %Kleened.Core.OCI.Layout{}} =
             Kleened.Core.OCI.Layout.open(download_dir)

    # the protocol handshake went through the token flow: challenge first, then
    # an unauthenticated token request, then the authorized manifest request
    requests = RegistryDouble.requests(listener)
    assert {"GET", "/v2/", nil, _} = List.first(requests)
    assert Enum.any?(requests, fn {_, path, _, _} -> path =~ "/token" end)

    assert Enum.any?(requests, fn {_, path, auth, _} ->
             path =~ "/manifests/" and auth == "double-anonymous-token"
           end)
  end

  test "pull rejects a manifest served with corrupted bytes", %{layout_dir: root} do
    # corrupt the manifest blob so the served bytes do not match its digest
    {:ok, listener, port} = RegistryDouble.start(root, [fixture_manifest_digest(root)])
    on_exit(fn -> RegistryDouble.stop(listener) end)

    # a corrupted manifest is rejected — either as a digest mismatch or as a
    # decode failure, depending on where the corruption lands
    assert {:error, reason} =
             Registry.pull("127.0.0.1:#{port}/test/minimal:latest",
               base_url: "http://127.0.0.1:#{port}"
             )

    assert reason =~ "digest" or reason =~ "decode" or reason =~ "manifest"
  end

  test "pull of an unknown tag reports the failure", %{layout_dir: root} do
    {:ok, listener, port} = RegistryDouble.start(root)
    on_exit(fn -> RegistryDouble.stop(listener) end)

    assert {:error, reason} =
             Registry.pull("127.0.0.1:#{port}/test/minimal:no-such-tag",
               base_url: "http://127.0.0.1:#{port}"
             )

    assert reason =~ "no-such-tag"
  end

  test "pull with a progress callback emits per-layer messages", %{layout_dir: root} do
    {:ok, listener, port} = RegistryDouble.start(root)
    on_exit(fn -> RegistryDouble.stop(listener) end)

    test_pid = self()

    assert {:ok, _} =
             Registry.pull("127.0.0.1:#{port}/test/minimal:latest",
               base_url: "http://127.0.0.1:#{port}",
               progress: fn msg -> send(test_pid, {:progress, msg}) end
             )

    assert_received {:progress, msg}
    assert msg =~ "layer"
  end

  # -- helpers ---------------------------------------------------------------

  defp fixture_manifest_digest(root) do
    {:ok, %{"manifests" => [descriptor | _]}} =
      Jason.decode(File.read!(Path.join(root, "index.json")))

    descriptor["digest"]
  end
end
