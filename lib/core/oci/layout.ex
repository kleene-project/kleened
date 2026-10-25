defmodule Kleened.Core.OCI.Layout do
  @moduledoc """
  Reading and validation of OCI image layouts on disk.

  A layout is a directory with an `oci-layout` marker, an `index.json`
  referring to one or more image manifests, and content-addressed blobs under
  `blobs/sha256/`. `open/2` selects a manifest from the index (by digest,
  ref-name annotation, or platform), verifies the digest of every blob it
  reads, and returns the manifest, its config, and the layer descriptors.
  """

  @enforce_keys [:root, :manifest, :config, :layers, :manifest_digest]
  defstruct [:root, :manifest, :config, :layers, :manifest_digest]

  @type t :: %__MODULE__{
          root: Path.t(),
          manifest: map(),
          config: map(),
          layers: [map()],
          manifest_digest: String.t()
        }

  @manifest_media_type "application/vnd.oci.image.manifest.v1+json"
  @config_media_type "application/vnd.oci.image.config.v1+json"

  @doc """
  Open the OCI layout at `root`.

  Options:

  - `:digest` — select the index entry with this manifest digest
  - `:ref` — select the entry annotated with this `org.opencontainers.image.ref.name`
  - `:platform` — `{os, arch}` tuple selecting an entry whose platform matches;
    entries without a platform annotation are matched when they are the only one
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def open(root, opts \\ []) do
    with {:ok, index} <- read_index(root),
         {:ok, descriptor} <- select_manifest(index, opts),
         {:ok, manifest} <- read_blob_json(root, descriptor, @manifest_media_type),
         {:ok, config} <- read_blob_json(root, manifest["config"], @config_media_type) do
      layers = manifest["layers"] || []

      case valid_layers?(layers) do
        true ->
          {:ok,
           %__MODULE__{
             root: root,
             manifest: manifest,
             config: config,
             layers: layers,
             manifest_digest: descriptor["digest"]
           }}

        false ->
          {:error, "manifest has no valid layers"}
      end
    end
  end

  @doc "Path of a blob within the layout, given its full `sha256:<hex>` digest."
  @spec blob_path(Path.t(), String.t()) :: Path.t()
  def blob_path(root, "sha256:" <> digest), do: Path.join([root, "blobs", "sha256", digest])

  @doc "Verify a file against its `sha256:<hex>` digest."
  @spec verify_file(Path.t(), String.t()) :: :ok | {:error, String.t()}
  def verify_file(path, "sha256:" <> expected) do
    actual = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

    if actual == expected do
      :ok
    else
      {:error, "digest mismatch for #{path}: expected sha256:#{expected}, got sha256:#{actual}"}
    end
  end

  defp read_index(root) do
    marker = Path.join(root, "oci-layout")
    index_path = Path.join(root, "index.json")

    with true <-
           File.exists?(marker) ||
             {:error, "not an OCI layout: missing oci-layout marker in #{root}"},
         {:ok, index_bin} <- read_file(index_path),
         {:ok, %{"manifests" => manifests}} <- Jason.decode(index_bin) do
      {:ok, manifests}
    else
      {:error, _} = error -> error
      false -> {:error, "not an OCI layout: missing oci-layout marker in #{root}"}
    end
  end

  defp select_manifest(manifests, opts) do
    case Keyword.get(opts, :digest) do
      nil ->
        select_by_ref_or_platform(manifests, opts)

      digest ->
        case Enum.find(manifests, &(&1["digest"] == digest)) do
          nil -> {:error, "no manifest with digest #{digest} in index"}
          descriptor -> {:ok, descriptor}
        end
    end
  end

  defp select_by_ref_or_platform(manifests, opts) do
    ref = Keyword.get(opts, :ref)
    platform = Keyword.get(opts, :platform)

    cond do
      ref != nil ->
        case Enum.find(
               manifests,
               &(&1["annotations"]["org.opencontainers.image.ref.name"] == ref)
             ) do
          nil -> {:error, "no manifest annotated with ref name #{ref}"}
          descriptor -> {:ok, descriptor}
        end

      platform != nil ->
        {os, arch} = platform

        case Enum.find(manifests, fn descriptor ->
               plat = descriptor["platform"]
               plat != nil and plat["os"] == os and plat["architecture"] == arch
             end) do
          nil ->
            {:error,
             "no manifest for platform #{os}/#{arch} (index has: #{inspect(available_platforms(manifests))})"}

          descriptor ->
            {:ok, descriptor}
        end

      manifests == [] ->
        {:error, "index has no manifests"}

      length(manifests) == 1 ->
        {:ok, hd(manifests)}

      true ->
        {:error, "ambiguous index: multiple manifests and no digest, ref or platform selector"}
    end
  end

  defp available_platforms(manifests) do
    manifests
    |> Enum.map(& &1["platform"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&"#{&1["os"]}/#{&1["architecture"]}")
  end

  defp valid_layers?(layers) when is_list(layers) and layers != [] do
    Enum.all?(layers, &(&1["digest"] != nil and &1["size"] != nil))
  end

  defp valid_layers?(_), do: false

  defp read_blob_json(root, descriptor, expected_media_type) do
    digest = descriptor["digest"]
    media_type = descriptor["mediaType"]

    with :ok <- check_media_type(media_type, expected_media_type),
         {:ok, bin} <- read_verified_blob(root, digest) do
      Jason.decode(bin)
    end
  end

  defp check_media_type(actual, expected) do
    if actual == nil or actual == expected do
      :ok
    else
      {:error, "unexpected media type #{actual}, expected #{expected}"}
    end
  end

  defp read_verified_blob(root, "sha256:" <> _ = digest) do
    path = blob_path(root, digest)

    with {:ok, bin} <- read_file(path),
         :ok <- verify_content(bin, digest) do
      {:ok, bin}
    end
  end

  defp verify_content(bin, "sha256:" <> expected) do
    actual = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)

    if actual == expected do
      :ok
    else
      {:error, "digest mismatch for blob #{expected}: content hashed to sha256:#{actual}"}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, reason} -> {:error, "could not read #{path}: #{inspect(reason)}"}
    end
  end
end
