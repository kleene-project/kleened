defmodule Kleened.Test.OCIFixtures do
  @moduledoc """
  Builds deterministic OCI image layouts in temp directories for tests.

  Every layout is a complete, digest-correct OCI image layout:

      <root>/oci-layout
      <root>/index.json
      <root>/blobs/sha256/<digest>...

  Layers are built as uncompressed tar files whose entries are given as
  `{path, content}` pairs or `{path, :dir}` markers. Layer media type is
  `application/vnd.oci.image.layer.v1.tar` (uncompressed) so tests can
  inspect blobs with `:erl_tar` without gzip concerns.
  """

  alias Kleened.Core.OCI.Ref

  @layer_media_type "application/vnd.oci.image.layer.v1.tar"
  @manifest_media_type "application/vnd.oci.image.manifest.v1+json"
  @config_media_type "application/vnd.oci.image.config.v1+json"

  @doc """
  Build an OCI layout in `dir` from `layers` (lists of `{path, content}` /
  `{path, :dir}` pairs) and an optional config `:cmd` / `:env` / `:arch` /
  `:os` override. Returns `{root, manifest_descriptor}` where the descriptor
  is the index entry for the single manifest.
  """
  @spec build(Path.t(), keyword()) :: {Path.t(), map()}
  def build(dir, opts \\ []) do
    layers =
      opts
      |> Keyword.get(:layers, [])
      |> Enum.map(fn entries -> build_layer_blob(dir, entries) end)

    config = build_config_blob(dir, opts)
    manifest = build_manifest_blob(dir, config, layers, opts)
    write_index(dir, manifest, opts)
  end

  @doc "Write `content` into `dir/blobs/sha256/<sha256(content)>`; returns the descriptor."
  @spec write_blob(Path.t(), String.t()) :: map()
  def write_blob(dir, content) do
    digest = digest_from_content(content)
    blob_dir = Path.join(dir, "blobs/sha256")
    File.mkdir_p!(blob_dir)
    File.write!(Path.join(blob_dir, digest), content)

    %{
      "mediaType" => "application/octet-stream",
      "digest" => "sha256:" <> digest,
      "size" => byte_size(content)
    }
  end

  @doc "sha256 digest of `content`, hex-encoded without the algorithm prefix."
  @spec digest_from_content(binary()) :: String.t()
  def digest_from_content(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc "Path of a blob within a layout."
  @spec blob_path(Path.t(), String.t()) :: Path.t()
  def blob_path(root, "sha256:" <> digest), do: Path.join([root, "blobs", "sha256", digest])

  @doc "Corrupt one byte of an on-disk blob, keeping the filename (digest mismatch)."
  @spec corrupt_blob(Path.t()) :: :ok
  def corrupt_blob(path) do
    content = File.read!(path)
    File.write!(path, content <> "corrupted")
    :ok
  end

  defp build_layer_blob(dir, entries) do
    layer_src =
      Path.join(dir, "layer-src-#{digest_from_content(:erlang.term_to_binary(entries))}")

    File.mkdir_p!(layer_src)

    Enum.each(entries, fn
      {path, :dir} -> File.mkdir_p!(Path.join(layer_src, path))
      {path, content} -> write_layer_file(Path.join(layer_src, path), content)
    end)

    tar_path = Path.join(dir, "layer.tar")
    {_, 0} = System.cmd("/usr/bin/tar", ["-cf", tar_path, "-C", layer_src, "."])
    File.rm_rf!(layer_src)

    descriptor = write_blob(dir, File.read!(tar_path))
    File.rm!(tar_path)
    %{descriptor | "mediaType" => @layer_media_type}
  end

  # Layer content may be given as a binary (file content) or an mtime/mode tuple
  # `{content, mode, mtime}` for metadata-sensitive tests.
  defp write_layer_file(path, content) when is_binary(content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp write_layer_file(path, {:symlink, target}) do
    File.mkdir_p!(Path.dirname(path))
    File.ln_s!(target, path)
  end

  defp write_layer_file(path, {:hardlink, source}) do
    File.mkdir_p!(Path.dirname(path))
    # source is relative to the layer root, path's dir is layer-root/<dir>
    File.ln!(Path.join(Path.dirname(Path.dirname(path)), source), path)
  end

  defp write_layer_file(path, {:copy, source, mode}) do
    File.mkdir_p!(Path.dirname(path))
    File.copy!(source, path)
    File.chmod!(path, mode)
  end

  defp write_layer_file(path, {content, mode}) when is_binary(content) and is_integer(mode) do
    write_layer_file(path, content)
    File.chmod!(path, mode)
  end

  defp build_config_blob(dir, opts) do
    config = %{
      "created" => "2026-10-24T12:00:00Z",
      "architecture" => Keyword.get(opts, :arch, "amd64"),
      "os" => Keyword.get(opts, :os, "freebsd"),
      "config" =>
        Map.merge(
          %{
            "Cmd" => Keyword.get(opts, :cmd, ["/bin/sh"]),
            "Env" => Keyword.get(opts, :env, ["PATH=/bin:/usr/bin"])
          },
          opts
          |> Enum.filter(fn
            {:workdir, v} when not is_nil(v) -> true
            {:entrypoint, v} when not is_nil(v) -> true
            {:user, v} when not is_nil(v) -> true
            {:labels, v} when not is_nil(v) -> true
            _ -> false
          end)
          |> Map.new(fn {k, v} -> {oci_config_key(k), v} end)
        ),
      "rootfs" => %{
        "type" => "layers",
        "diff_ids" => []
      },
      "history" => [
        %{"created" => "2026-10-24T12:00:00Z", "created_by" => "kleened-test-fixture"}
      ]
    }

    content = Jason.encode!(config)
    descriptor = write_blob(dir, content)
    %{descriptor | "mediaType" => @config_media_type}
  end

  defp oci_config_key(:workdir), do: "WorkingDir"
  defp oci_config_key(:entrypoint), do: "Entrypoint"
  defp oci_config_key(:user), do: "User"
  defp oci_config_key(:labels), do: "Labels"

  defp build_manifest_blob(dir, config, layers, _opts) do
    manifest = %{
      "schemaVersion" => 2,
      "mediaType" => @manifest_media_type,
      "config" => config,
      "layers" => layers
    }

    content = Jason.encode!(manifest)
    descriptor = write_blob(dir, content)
    %{descriptor | "mediaType" => @manifest_media_type}
  end

  defp write_index(dir, manifest, opts) do
    ref_name = Keyword.get(opts, :ref, "test/minimal:latest")

    index = %{
      "schemaVersion" => 2,
      "manifests" => [
        Map.put(manifest, "annotations", %{"org.opencontainers.image.ref.name" => ref_name})
      ]
    }

    File.write!(Path.join(dir, "index.json"), Jason.encode!(index))
    File.write!(Path.join(dir, "oci-layout"), Jason.encode!(%{"imageLayoutVersion" => "1.0.0"}))

    {dir, manifest}
  end

  @doc "Reference fixture for Ref tests, kept here to avoid circular deps."
  def sample_ref,
    do: %Ref{registry: "docker.io", repository: "library/nginx", tag: "latest", digest: nil}
end
