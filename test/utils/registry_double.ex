defmodule Kleened.Test.RegistryDouble do
  @moduledoc false

  # An in-process OCI distribution registry serving `/v2/` from a fixture
  # layout, speaking the anonymous-token flavor of the protocol:
  #
  #   GET /v2/                       -> 401 + WWW-Authenticate: Bearer (once),
  #                                     200 with a valid bearer token
  #   GET /token?service=...&scope=.. -> {"token": <token>}
  #   GET /v2/<repo>/manifests/<ref> -> manifest/index bytes (by Accept)
  #   GET /v2/<repo>/blobs/<digest>  -> blob bytes
  #
  # A tag resolves through index.json: the manifest whose
  # org.opencontainers.image.ref.name annotation ends with `:<tag>` (or equals
  # the ref) is served. `corrupt` digests are served with a modified body, for
  # digest-verification failure tests. `start/2` returns
  # `{:ok, listener, port}`; `requests/1` returns the recorded
  # `{method, path, headers}` triples; `stop/1` shuts the listener down.

  @behaviour :cowboy_handler

  @token "double-anonymous-token"

  defstruct [:layout_dir, :corrupt, :listener]

  @spec start(Path.t(), [String.t()]) :: {:ok, atom(), :inet.port_number()} | {:error, term()}
  def start(layout_dir, corrupt \\ []) do
    listener = :"registry_double_#{:erlang.unique_integer([:positive])}"
    # The unit tier runs with --no-start, so ranch/cowboy may not be running:
    # start a private supervisor owning this listener.
    {:ok, _} = ensure_registry_started()
    # The recording table must outlive the request processes, so this process
    # owns it.
    ensure_table()

    state = %__MODULE__{layout_dir: layout_dir, corrupt: corrupt, listener: listener}
    dispatch = :cowboy_router.compile([{:_, [{"/[...]", __MODULE__, state}]}])

    case :cowboy.start_clear(listener, [port: 0], %{env: %{dispatch: dispatch}}) do
      {:ok, _pid} ->
        {:ok, listener, :ranch.get_port(listener)}

      error ->
        error
    end
  end

  defp ensure_registry_started do
    # --no-start skips the supervision tree; start cowboy (and ranch beneath it)
    # on demand. Idempotent if something already started it.
    :application.ensure_all_started(:cowboy)
  end

  @spec stop(atom()) :: :ok
  def stop(listener), do: :cowboy.stop_listener(listener)

  @doc "Recorded `{method, path, authorization, accept}` tuples, oldest first."
  @spec requests(atom()) :: [{String.t(), String.t(), String.t() | nil, String.t() | nil}]
  def requests(listener) do
    ensure_table()
    :ets.lookup_element(:registry_double_requests, listener, 2)
  rescue
    _ -> []
  end

  defp record(listener, method, path, auth, accept) do
    ensure_table()
    :ets.insert(:registry_double_requests, {listener, {method, path, auth, accept}})
  end

  defp ensure_table do
    case :ets.whereis(:registry_double_requests) do
      :undefined -> :ets.new(:registry_double_requests, [:public, :named_table, :bag])
      _ -> :ok
    end
  end

  @impl :cowboy_handler
  def init(req, state) do
    method = :cowboy_req.method(req)
    path = :cowboy_req.path(req)

    auth =
      case :cowboy_req.parse_header("authorization", req) do
        {:bearer, token} -> token
        _ -> nil
      end

    accept = :cowboy_req.header("accept", req)
    record(state.listener, method, path, auth, accept)

    req = reply(req, method, path, auth, accept, state)
    {:ok, req, state}
  end

  defp reply(req, "GET", "/v2/", nil, _accept, _state) do
    challenge = challenge_header(req)
    :cowboy_req.reply(401, %{"www-authenticate" => challenge}, "", req)
  end

  defp reply(req, "GET", "/v2/", _token, _accept, _state) do
    :cowboy_req.reply(200, %{"content-type" => "application/json"}, "{}", req)
  end

  defp reply(req, "GET", "/token" <> _, _auth, _accept, _state) do
    body = Jason.encode!(%{"token" => @token})
    :cowboy_req.reply(200, %{"content-type" => "application/json"}, body, req)
  end

  defp reply(req, "GET", "/v2/" <> rest, token, accept, state) when token != nil do
    # A repo path may itself contain slashes; route on the last two segments.
    case String.split(rest, "/") |> Enum.split(-2) do
      {_repo_parts, ["manifests", ref]} -> serve_manifest(req, ref, accept, state)
      {_repo_parts, ["blobs", digest]} -> serve_blob(req, digest, state)
      _ -> :cowboy_req.reply(404, %{}, "not found", req)
    end
  end

  defp reply(req, _method, _path, _auth, _accept, _state) do
    :cowboy_req.reply(404, %{}, "not found", req)
  end

  defp challenge_header(req) do
    host = :cowboy_req.host(req)
    port = :cowboy_req.port(req)
    "Bearer realm=\"http://#{host}:#{port}/token\",service=\"registry-double\""
  end

  defp serve_manifest(req, ref, accept, %__MODULE__{layout_dir: layout_dir} = state) do
    with {:ok, index} <- read_json(Path.join(layout_dir, "index.json")),
         {:ok, descriptor} <- find_descriptor(index, ref) do
      cond do
        accept == nil or String.contains?(accept, descriptor["mediaType"]) ->
          blob = Path.join([layout_dir, "blobs", "sha256", digest_hex(descriptor["digest"])])
          bytes = maybe_corrupt(File.read!(blob), descriptor["digest"], state)

          :cowboy_req.reply(
            200,
            %{
              "content-type" => descriptor["mediaType"],
              "docker-content-digest" => descriptor["digest"]
            },
            bytes,
            req
          )

        true ->
          :cowboy_req.reply(404, %{}, "manifest not found for accept #{accept}", req)
      end
    else
      _ -> :cowboy_req.reply(404, %{}, "manifest not found", req)
    end
  end

  defp serve_blob(req, digest, %__MODULE__{layout_dir: layout_dir} = state) do
    blob = Path.join([layout_dir, "blobs", "sha256", digest_hex(digest)])

    case File.read(blob) do
      {:ok, bytes} ->
        bytes = maybe_corrupt(bytes, "sha256:" <> Path.basename(blob), state)
        :cowboy_req.reply(200, %{"content-type" => "application/octet-stream"}, bytes, req)

      _ ->
        :cowboy_req.reply(404, %{}, "blob not found", req)
    end
  end

  defp maybe_corrupt(bytes, digest, %__MODULE__{corrupt: corrupt}) do
    if digest in corrupt, do: bytes <> "corrupted", else: bytes
  end

  defp find_descriptor(index, "sha256:" <> _ = digest),
    do: find_in_index(index, &(&1["digest"] == digest))

  defp find_descriptor(index, tag),
    do:
      find_in_index(index, fn descriptor ->
        case descriptor["annotations"]["org.opencontainers.image.ref.name"] do
          nil -> false
          ref_name -> ref_name == tag or String.ends_with?(ref_name, ":" <> tag)
        end
      end)

  defp find_in_index(index, predicate) do
    case Enum.find(index["manifests"] || [], predicate) do
      nil -> {:error, :not_found}
      descriptor -> {:ok, descriptor}
    end
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, bytes} -> Jason.decode(bytes)
      error -> error
    end
  end

  defp digest_hex("sha256:" <> hex), do: hex
end
