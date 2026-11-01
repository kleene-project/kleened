defmodule OCIImageImportTest do
  use Kleened.Test.ConnCase
  alias Kleened.API.Schemas
  alias Kleened.Core.MetaData
  alias Kleened.Test.OCIFixtures
  import TestHelper

  @tmp_dir Path.join(System.tmp_dir(), "kleened-oci-import-test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  # Build a layout, tar it up as an importable archive, and return its path.
  defp import_archive(name, build_opts) do
    dir = Path.join(@tmp_dir, "layout-#{name}")
    File.mkdir_p!(dir)
    OCIFixtures.build(dir, build_opts)
    archive = Path.join(@tmp_dir, "#{name}.txz")
    {_, 0} = System.cmd("/usr/bin/tar", ["-cf", archive, "-C", dir, "."])
    archive
  end

  # All entries of a minimal but *executable* layer: a real /bin/sh and
  # /bin/cat from /rescue (statically linked), kleened's exec wrapper
  # /usr/bin/env with the complete runtime library set from /lib and
  # /libexec, and the test content. The jail needs /dev for mount.devfs,
  # /etc/pwd.db for getpwnam, and /root as the default working directory.
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

  # kleened's exec runs `/usr/bin/env <env> <cmd>` inside the jail; env is
  # dynamically linked, so the layer carries the loader (executable!) and
  # every library of /lib (wholesale — enumerating the closure is fragile
  # across releases).
  defp runtime_libs do
    ["/libexec/ld-elf.so.1" | Path.wildcard("/lib/*.so.*")]
    |> Enum.map(fn source ->
      mode = if Path.basename(source) == "ld-elf.so.1", do: 0o555, else: 0o444
      {String.trim_leading(source, "/"), {:copy, source, mode}}
    end)
  end

  test "import an OCI layout archive and run a container from it" do
    archive = import_archive("single", layers: [executable_layer()])

    assert {:ok, image_id} = import_via_websocket(archive, "oci-test:single")

    # The image is registered with OCI metadata and materialized on ZFS
    {:ok, image} = MetaData.get_image(image_id) |> then(&{:ok, &1})
    assert image.name == "oci-test"
    assert image.tag == "single"
    assert image.source == "oci"
    assert image.cmd == ["/bin/sh"]
    assert image.env == ["PATH=/bin:/usr/bin"]
    assert image.digest =~ "sha256:"

    # Layer snapshot plus the regular @image snapshot
    assert {_, 0} =
             System.cmd("/sbin/zfs", ~w"list -t snapshot -o name -H #{image.dataset}@layer-1")

    assert {_, 0} =
             System.cmd("/sbin/zfs", ~w"list -t snapshot -o name -H #{image.dataset}@image")

    # A container from the imported image sees the layer content
    container_config = %{
      name: "oci-import-test",
      image: image_id,
      cmd: ["cat", "/etc/hello"]
    }

    {container_id, closing, output} = TestHelper.container_valid_run(container_config)
    assert closing =~ "exit-code 0"
    assert Enum.any?(output, &String.contains?(&1, "world"))

    api_spec = Kleened.API.Spec.spec()
    TestHelper.container_remove(api_spec, container_id)
    TestHelper.image_remove(image_id)
  end

  test "re-importing the same digest with the same tag returns the existing image" do
    archive = import_archive("idem", layers: [[{"a", "b"}]])

    assert {:ok, id1} = import_via_websocket(archive, "oci-test:idem")
    assert {:ok, id2} = import_via_websocket(archive, "oci-test:idem")
    assert id1 == id2
  after
    case MetaData.get_image("oci-test:idem") do
      %Schemas.Image{id: id} -> TestHelper.image_remove(id)
      :not_found -> :ok
    end
  end

  test "container from OCI image inherits entrypoint and workdir" do
    archive =
      import_archive("meta",
        layers: [executable_layer()],
        cmd: ["/bin/cat", "/etc/hello"],
        workdir: "/etc"
      )

    assert {:ok, image_id} = import_via_websocket(archive, "oci-meta:latest")

    # entrypoint ++ cmd is the effective command; workdir inherited
    container_config = %{name: "oci-meta-container", image: image_id}
    %{id: container_id} = TestHelper.container_create(container_config)

    container = MetaData.get_container(container_id)
    # cmd from the image config (no entrypoint in this fixture)
    assert container.cmd == ["/bin/cat", "/etc/hello"]
    assert container.workdir == "/etc"

    api_spec = Kleened.API.Spec.spec()
    TestHelper.container_remove(api_spec, container_id)
    TestHelper.image_remove(image_id)
  end

  test "import fails cleanly on a corrupt layout" do
    dir = Path.join(@tmp_dir, "corrupt")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "not-a-layout.txt"), "junk")
    archive = Path.join(@tmp_dir, "corrupt.txz")
    {_, 0} = System.cmd("/usr/bin/tar", ["-cf", archive, "-C", dir, "."])

    assert {:error, reason} = import_via_websocket(archive, "oci-test:corrupt")
    assert reason =~ "not an OCI layout" or reason =~ "image import failed"
  end

  # Drive /images/import over the raw websocket (test/utils/ws.ex — the shared
  # TestHelper receive loop races on abnormal closes).
  defp import_via_websocket(archive, tag) do
    Kleened.Test.WS.send_config_and_collect("/images/import", %{url: archive, tag: tag})
  end
end
