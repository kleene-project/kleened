defmodule OCIImagePullTest do
  use Kleened.Test.ConnCase
  alias Kleened.API.Schemas
  alias Kleened.Core.MetaData
  alias Kleened.Test.{OCIFixtures, RegistryDouble}
  import TestHelper

  @kleened_host "/var/run/kleened.sock"
  @tmp_dir Path.join(System.tmp_dir(), "kleened-oci-pull-test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)

    # A registry double serving a fixture layout; the daemon pulls from it
    # over http (localhost registries default to plain http).
    layout_dir = Path.join(@tmp_dir, "layout")
    File.mkdir_p!(layout_dir)
    OCIFixtures.build(layout_dir, layers: [executable_layer()], cmd: ["/bin/cat", "/etc/hello"])

    {:ok, listener, port} = RegistryDouble.start(layout_dir)
    on_exit(fn -> RegistryDouble.stop(listener) end)

    %{registry: "127.0.0.1:#{port}", ref: "127.0.0.1:#{port}/test/minimal:latest"}
  end

  # All entries of a minimal but *executable* layer (same rationale as the
  # import test's fixture).
  defp executable_layer do
    [
      {"dev", :dir},
      {"etc", :dir},
      {"root", :dir},
      {"etc/hello", "world"},
      {"etc/passwd", "root:*:0:0:Charlie &:/root:/bin/sh\n"},
      {"etc/group", "wheel:*:0:root\n"},
      {"etc/pwd.db", {:copy, "/etc/pwd.db", 0o644}},
      {"bin/sh", {:copy, "/rescue/sh", 0o755}},
      {"bin/cat", {:copy, "/rescue/cat", 0o755}},
      {"usr/bin/env", {:copy, "/usr/bin/env", 0o755}}
      | runtime_libs()
    ]
  end

  defp runtime_libs do
    ["/libexec/ld-elf.so.1" | Path.wildcard("/lib/*.so.*")]
    |> Enum.map(fn source ->
      mode = if Path.basename(source) == "ld-elf.so.1", do: 0o555, else: 0o444
      {String.trim_leading(source, "/"), {:copy, source, mode}}
    end)
  end

  test "pull an image from a registry and run a container from it", %{ref: ref} do
    assert {:ok, image_id} = pull_via_websocket(ref)

    {:ok, image} = MetaData.get_image(image_id) |> then(&{:ok, &1})
    assert image.name == "test/minimal"
    assert image.tag == "latest"
    assert image.source == "oci"
    assert image.digest =~ "sha256:"

    assert {_, 0} =
             System.cmd("/sbin/zfs", ~w"list -t snapshot -o name -H #{image.dataset}@layer-1")

    container_config = %{
      name: "oci-pull-test",
      image: image_id,
      cmd: ["/bin/cat", "/etc/hello"]
    }

    {container_id, closing, output} = TestHelper.container_valid_run(container_config)
    assert closing =~ "exit-code 0"
    assert Enum.any?(output, &String.contains?(&1, "world"))

    api_spec = Kleened.API.Spec.spec()
    TestHelper.container_remove(api_spec, container_id)
    TestHelper.image_remove(image_id)
  end

  test "re-pulling the same digest returns the existing image", %{ref: ref} do
    assert {:ok, id1} = pull_via_websocket(ref)
    assert {:ok, id2} = pull_via_websocket(ref)
    assert id1 == id2
  after
    case MetaData.get_image("test/minimal:latest") do
      %Schemas.Image{id: id} -> TestHelper.image_remove(id)
      :not_found -> :ok
    end
  end

  test "pull of an unknown tag fails cleanly", %{registry: registry} do
    assert {:error, reason} = pull_via_websocket("#{registry}/test/minimal:no-such-tag")
    assert reason =~ "no-such-tag" or reason =~ "404"
  end

  # Drive /images/pull over the raw websocket (same rationale as the import
  # test: the shared TestHelper receive loop races on abnormal closes).
  defp pull_via_websocket(ref) do
    {:ok, conn} = :gun.open_unix(@kleened_host, %{protocols: [:http]})
    {:ok, _} = :gun.await_up(conn)
    :gun.ws_upgrade(conn, "/images/pull")

    stream =
      receive do
        {:gun_upgrade, ^conn, ref_, ["websocket"], _} -> ref_
      after
        5_000 -> flunk("websocket upgrade timed out")
      end

    :gun.ws_send(conn, stream, {:text, Jason.encode!(%{ref: ref})})
    collect_pull_frames(conn, stream)
  end

  defp collect_pull_frames(conn, stream) do
    receive do
      {:gun_ws, ^conn, ^stream, {:text, msg}} ->
        case Jason.decode(msg) do
          {:error, _} -> collect_pull_frames(conn, stream)
          {:ok, decoded} -> decode_pull_frame(decoded, conn, stream)
        end

      {:gun_ws, ^conn, ^stream, {:close, _code, msg}} ->
        {:ok, decoded} = Jason.decode(msg)
        pull_result(decoded)

      {:gun_down, ^conn, :ws, _reason, _} ->
        receive do
          {:gun_ws, ^conn, ^stream, {:close, _code, msg}} ->
            {:ok, decoded} = Jason.decode(msg)
            pull_result(decoded)
        after
          500 -> flunk("websocket closed before result frame")
        end
    after
      30_000 -> flunk("timed out waiting for pull result")
    end
  end

  defp decode_pull_frame(%{"msg_type" => "error", "message" => message}, _conn, _stream) do
    {:error, message}
  end

  defp decode_pull_frame(_progress_frame, conn, stream) do
    collect_pull_frames(conn, stream)
  end

  defp pull_result(%{"msg_type" => "error", "message" => message}), do: {:error, message}
  defp pull_result(%{"msg_type" => "closing", "data" => data}), do: {:ok, data}
end
