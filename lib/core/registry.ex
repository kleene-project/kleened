defmodule Kleened.Core.Registry do
  @moduledoc false

  # OCI distribution registry client ("pull" only). Speaks the anonymous-token
  # flavor of the Docker/OCI v2 protocol:
  #
  #   1. GET /v2/                       -> 401 challenge (or 200: no auth)
  #   2. GET <realm>?service=&scope=    -> {"token": ...}
  #   3. GET /v2/<repo>/manifests/<ref> -> manifest (or index; by Accept)
  #   4. GET /v2/<repo>/blobs/<digest>  -> blob bytes
  #
  # Every downloaded blob is sha256-verified against its descriptor before it
  # is used. The result is an on-disk OCI layout (index.json + blobs/) that
  # `Core.OCI.Layout.open/2` consumes.

  alias Kleened.Core.OCI.Ref

  # gun registers its connection supervisor under its own application; the
  # test suite may run with --no-start, so ensure gun on demand.
  defp ensure_gun_started do
    case :application.ensure_all_started(:gun) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "could not start gun: #{inspect(reason)}"}
    end
  end

  @accept_manifests ~w(application/vnd.oci.image.manifest.v1+json
                       application/vnd.docker.distribution.manifest.v2+json)

  @accept_index ~w(application/vnd.oci.image.index.v1+json
                   application/vnd.docker.distribution.manifest.list.v2+json)

  @default_accept ["application/vnd.oci.image.index.v1+json"] ++
                    ["application/vnd.docker.distribution.manifest.list.v2+json"] ++
                    ["application/vnd.oci.image.manifest.v1+json"] ++
                    ["application/vnd.docker.distribution.manifest.v2+json"]

  @type progress() :: (String.t() -> any())

  @spec pull(String.t(), keyword()) ::
          {:ok, %{root: Path.t(), manifest: map(), config: map(), layers: [map()]}}
          | {:error, String.t()}
  def pull(reference, opts \\ []) do
    with {:ok, ref} <- parse_ref(reference),
         :ok <- ensure_gun_started(),
         {:ok, conn} <- open(base_url(ref, opts), opts) do
      pull(conn, ref, opts)
    end
  end

  defp pull(conn, %Ref{} = ref, opts) do
    progress = Keyword.get(opts, :progress)
    base = base_url(ref, opts)
    repo = ref.repository

    with {:ok, token} <- authenticate(conn, base, repo) do
      ref_string = ref.digest || ref.tag || "latest"
      accept = Enum.join(@default_accept, ", ")

      with {:ok, manifest, manifest_digest, media_type} <-
             get_manifest(conn, base, repo, ref_string, token, accept) do
        download_dir = download_dir(opts)

        with {:ok, layout} <-
               fetch_layout(conn, base, repo, manifest, manifest_digest, media_type, token,
                 download_dir: download_dir,
                 progress: progress
               ) do
          :gun.close(conn)
          {:ok, layout}
        else
          {:error, reason} ->
            :gun.close(conn)
            {:error, reason}
        end
      end
    end
  end

  # -- reference and URL handling --------------------------------------------

  defp parse_ref(reference) do
    case Ref.parse(reference) do
      {:ok, ref} -> {:ok, ref}
      :error -> {:error, "invalid image reference #{reference}"}
    end
  end

  defp base_url(%Ref{registry: registry}, opts) do
    case Keyword.get(opts, :base_url) do
      nil -> "https://#{registry}"
      override -> String.replace_trailing(override, "/", "")
    end
  end

  defp download_dir(opts) do
    Keyword.get_lazy(opts, :download_dir, fn ->
      Path.join(System.tmp_dir(), "kleened-registry-pull-#{:erlang.unique_integer([:positive])}")
    end)
  end

  # -- HTTP plumbing ---------------------------------------------------------

  defp open(base_url, _opts) do
    uri = URI.parse(base_url)
    transport = if uri.scheme == "https", do: :tls, else: :tcp
    port = uri.port || default_port(transport)

    gun_opts = %{transport: transport, retry: 0, protocols: [:http]}

    case :gun.open(String.to_charlist(uri.host), port, gun_opts) do
      {:ok, conn} ->
        case :gun.await_up(conn) do
          {:ok, _} -> {:ok, conn}
          error -> {:error, "could not connect to registry: #{inspect(error)}"}
        end

      error ->
        {:error, "could not open connection to registry: #{inspect(error)}"}
    end
  end

  defp default_port(:tls), do: 443
  defp default_port(:tcp), do: 80

  defp request(conn, method, path, headers, body \\ "") do
    stream_ref =
      :gun.request(
        conn,
        method,
        String.to_charlist(path),
        headers,
        body
      )

    await_response(conn, stream_ref)
  end

  defp await_response(conn, stream_ref) do
    receive do
      {:gun_response, ^conn, ^stream_ref, :fin, status, headers} ->
        {:ok, status, headers, ""}

      {:gun_response, ^conn, ^stream_ref, :nofin, status, headers} ->
        case await_data(conn, stream_ref, "") do
          {:ok, body} -> {:ok, status, headers, body}
          error -> error
        end

      {:gun_error, ^conn, ^stream_ref, reason} ->
        {:error, "connection error: #{inspect(reason)}"}
    after
      10_000 -> {:error, "registry request timed out"}
    end
  end

  defp await_data(conn, stream_ref, acc) do
    receive do
      {:gun_data, ^conn, ^stream_ref, :fin, data} ->
        {:ok, acc <> data}

      {:gun_data, ^conn, ^stream_ref, :nofin, data} ->
        await_data(conn, stream_ref, acc <> data)

      {:gun_error, ^conn, ^stream_ref, reason} ->
        {:error, "connection error while receiving body: #{inspect(reason)}"}
    after
      10_000 -> {:error, "registry request timed out"}
    end
  end

  # -- auth ------------------------------------------------------------------

  defp authenticate(conn, base, repo) do
    case request(conn, "GET", "/v2/", []) do
      {:ok, 200, _headers, _body} ->
        {:ok, nil}

      {:ok, 401, headers, _body} ->
        challenge = challenge(headers)

        with {:ok, token_url} <- token_endpoint(challenge, repo),
             {:ok, token_conn} <- open(token_url, []),
             {:ok, 200, _token_headers, body} <-
               request(token_conn, "GET", token_path(token_url), []),
             {:ok, %{"token" => token}} <- Jason.decode(body) do
          :gun.close(token_conn)
          {:ok, token}
        else
          {:ok, status, _headers, _body} ->
            {:error, "registry token endpoint returned #{status}"}

          {:error, reason} ->
            {:error, "could not obtain registry token: #{reason}"}

          _ ->
            {:error, "could not parse token response"}
        end

      {:ok, status, _headers, _body} ->
        {:error, "registry returned #{status} for /v2/"}

      error ->
        error
    end
  end

  # The token endpoint may live on another host than the registry (e.g.
  # auth.docker.io), so open the realm URL itself and request only its path.
  defp token_path(token_url) do
    uri = URI.parse(token_url)
    query = if uri.query, do: "?" <> uri.query, else: ""
    uri.path <> query
  end

  defp challenge(headers) do
    header =
      Enum.find_value(headers, fn
        {<<"www-authenticate">>, value} -> value
        {key, value} when is_list(key) -> if to_string(key) == "www-authenticate", do: value
        _ -> nil
      end)

    case header do
      nil -> %{}
      value -> parse_challenge(value)
    end
  end

  defp parse_challenge("Bearer " <> params) do
    params
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn kv -> String.split(kv, "=", parts: 2) end)
    |> Enum.reject(&(length(&1) == 1))
    |> Map.new(fn [k, v] -> {k, String.trim(v, "\"")} end)
  end

  defp parse_challenge(_), do: %{}

  defp token_endpoint(%{"realm" => realm} = challenge, repo)
       when is_binary(realm) do
    query =
      URI.encode_query(%{
        "service" => Map.get(challenge, "service", ""),
        "scope" => "repository:#{repo}:pull"
      })

    realm =
      if String.contains?(realm, "?"), do: realm <> "&" <> query, else: realm <> "?" <> query

    {:ok, realm}
  end

  defp token_endpoint(_challenge, _repo), do: {:error, "registry challenge has no token realm"}

  # -- manifest --------------------------------------------------------------

  defp get_manifest(conn, base, repo, ref_string, token, accept) do
    path = "/v2/#{repo}/manifests/#{ref_string}"
    headers = [{"accept", accept} | auth_headers(token)]

    case request(conn, "GET", path, headers) do
      {:ok, 200, resp_headers, body} ->
        media_type = content_type(resp_headers)
        digest = digest_header(resp_headers)

        with {:ok, decoded} <- decode_manifest_or_index(body, media_type) do
          case verify_manifest_digest(body, digest, media_type) do
            :ok -> {:ok, decoded, digest || digest_of(body), media_type}
            error -> error
          end
        else
          {:error, %Jason.DecodeError{} = reason} ->
            {:error,
             "could not decode manifest for #{repo}:#{ref_string}: #{Exception.message(reason)}"}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, 404, _headers, _body} ->
        {:error, "registry returned 404 for manifest #{repo}:#{ref_string}"}

      {:ok, status, _headers, _body} ->
        {:error, "registry returned #{status} for manifest #{repo}:#{ref_string}"}

      error ->
        error
    end
  end

  defp decode_manifest_or_index(body, media_type) do
    with {:ok, decoded} <- Jason.decode(body) do
      cond do
        media_type in @accept_index or Map.has_key?(decoded, "manifests") ->
          {:ok, decoded}

        media_type in @accept_manifests or Map.has_key?(decoded, "layers") ->
          {:ok, decoded}

        true ->
          {:error, "unexpected manifest media type #{media_type}"}
      end
    end
  end

  defp verify_manifest_digest(_body, nil, _media_type), do: :ok

  defp verify_manifest_digest(body, digest, _media_type) do
    if digest_of(body) == digest do
      :ok
    else
      {:error, "manifest digest mismatch: served bytes do not match digest #{digest}"}
    end
  end

  # -- layout assembly -------------------------------------------------------

  defp fetch_layout(conn, base, repo, manifest, manifest_digest, media_type, token, opts) do
    download_dir = Keyword.fetch!(opts, :download_dir)
    progress = Keyword.get(opts, :progress)
    File.mkdir_p!(Path.join(download_dir, "blobs/sha256"))

    case manifest do
      %{"manifests" => _} ->
        # An index: select by platform (host default) and fetch that manifest.
        with {:ok, descriptor} <- select_platform_manifest(manifest["manifests"], opts),
             {:ok, inner} <- fetch_indexed_manifest(conn, repo, descriptor, token) do
          assemble_layout(conn, repo, inner, token, manifest_digest, download_dir, progress)
        end

      %{"layers" => _} ->
        assemble_layout(conn, repo, manifest, token, manifest_digest, download_dir, progress)
    end
  end

  defp select_platform_manifest(manifests, opts) do
    platform = Keyword.get(opts, :platform)

    case find_by_platform(manifests, platform) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        if platform == nil do
          error
        else
          case Enum.find(manifests, &(&1["platform"] == nil)) or List.first(manifests) do
            nil -> {:error, reason}
            descriptor -> {:ok, descriptor}
          end
        end
    end
  end

  defp find_by_platform(manifests, nil),
    do: {:error, "no manifests in index"}

  defp find_by_platform(manifests, {os, arch}) do
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
  end

  defp available_platforms(manifests) do
    Enum.map(manifests, fn
      %{"platform" => %{"os" => os, "architecture" => arch}} -> "#{os}/#{arch}"
      _ -> "unknown"
    end)
  end

  defp verify_descriptor(body, descriptor) do
    if digest_of(body) == descriptor["digest"] do
      :ok
    else
      {:error,
       "manifest digest mismatch: served bytes do not match digest #{descriptor["digest"]}"}
    end
  end

  defp fetch_indexed_manifest(conn, repo, descriptor, token) do
    path = "/v2/#{repo}/manifests/#{descriptor["digest"]}"
    headers = [{"accept", Enum.join(@default_accept, ", ")} | auth_headers(token)]

    case request(conn, "GET", path, headers) do
      {:ok, 200, _resp_headers, body} ->
        case Jason.decode(body) do
          {:ok, decoded} ->
            with :ok <- verify_descriptor(body, descriptor) do
              {:ok, decoded}
            end

          error ->
            {:error, "could not decode manifest: #{inspect(error)}"}
        end

      {:ok, 404, _headers, _body} ->
        {:error, "registry returned 404 for manifest #{descriptor["digest"]}"}

      {:ok, status, _headers, _body} ->
        {:error, "registry returned #{status} for manifest #{descriptor["digest"]}"}

      error ->
        error
    end
  end

  defp assemble_layout(conn, repo, manifest, token, manifest_digest, download_dir, progress) do
    total = length(Map.get(manifest, "layers", []))

    with {:ok, config} <-
           download_blob(conn, repo, manifest["config"], token, download_dir, "config") do
      layers =
        manifest["layers"]
        |> Enum.with_index(1)
        |> Enum.map(fn {layer, index} ->
          report(
            progress,
            "downloading layer #{index}/#{total} (#{digest_prefix(layer["digest"])})\n"
          )

          case download_blob(conn, repo, layer, token, download_dir, "layer") do
            {:ok, _blob} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end)
        |> Enum.find({:ok, :ok}, &match?({:error, _}, &1))

      case layers do
        {:ok, :ok} ->
          store_manifest_blob(download_dir, manifest, manifest_digest)
          write_layout_index(download_dir, manifest, manifest_digest)
          {:ok, layout_summary(download_dir, manifest, config)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The manifest blob itself belongs in the downloaded layout: Layout.open reads
  # it through the index descriptor.
  defp store_manifest_blob(download_dir, manifest, manifest_digest) do
    hex = String.replace_prefix(manifest_digest, "sha256:", "")
    blob_path = Path.join([download_dir, "blobs", "sha256", hex])
    File.write!(blob_path, Jason.encode!(manifest))
    :ok
  end

  defp download_blob(conn, repo, descriptor, token, download_dir, kind) do
    digest = descriptor["digest"]
    path = "/v2/#{repo}/blobs/#{digest}"
    headers = auth_headers(token)

    case request(conn, "GET", path, headers) do
      {:ok, 200, _resp_headers, body} ->
        verify_and_store(body, descriptor, download_dir, kind)

      {:ok, 404, _headers, _body} ->
        {:error, "#{kind} blob not found: #{digest}"}

      {:ok, status, _headers, _body} ->
        {:error, "registry returned #{status} for #{kind} blob #{digest}"}

      error ->
        {:error, "#{kind} blob download failed: #{inspect(error)}"}
    end
  end

  defp verify_and_store(body, descriptor, download_dir, kind) do
    digest = descriptor["digest"]

    if digest_of(body) == digest do
      hex = String.replace_prefix(digest, "sha256:", "")
      blob_path = Path.join([download_dir, "blobs", "sha256", hex])
      File.write!(blob_path, body)
      {:ok, blob_path}
    else
      {:error, "#{kind} digest mismatch: downloaded bytes do not match digest #{digest}"}
    end
  end

  defp write_layout_index(download_dir, manifest, manifest_digest) do
    index = %{
      "schemaVersion" => 2,
      "manifests" => [
        %{
          "mediaType" => manifest["mediaType"],
          "digest" => manifest_digest,
          "size" => byte_size(Jason.encode!(manifest))
        }
      ]
    }

    File.write!(Path.join(download_dir, "index.json"), Jason.encode!(index))
    File.write!(Path.join(download_dir, "oci-layout"), ~s({"imageLayoutVersion":"1.0.0"}))
    :ok
  end

  defp layout_summary(download_dir, manifest, config) do
    %{
      root: download_dir,
      manifest: manifest,
      config: config,
      layers: Map.get(manifest, "layers", [])
    }
  end

  # -- helpers ---------------------------------------------------------------

  defp auth_headers(nil), do: []

  defp auth_headers(token), do: [{"authorization", "Bearer " <> token}]

  defp content_type(headers) do
    Enum.find_value(headers, fn
      {<<"content-type">>, value} -> to_string(value)
      {key, value} when is_list(key) -> if to_string(key) == "content-type", do: to_string(value)
      _ -> nil
    end)
  end

  defp digest_header(headers) do
    Enum.find_value(headers, fn
      {<<"docker-content-digest">>, value} ->
        to_string(value)

      {key, value} when is_list(key) ->
        if to_string(key) == "docker-content-digest", do: to_string(value)

      _ ->
        nil
    end)
  end

  defp digest_of(body), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)

  defp digest_prefix("sha256:" <> hex), do: String.slice(hex, 0, 12)

  defp report(nil, _msg), do: :ok
  defp report(progress, msg), do: progress.(msg)
end
