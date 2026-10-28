defmodule Kleened.Core.OCI.Ref do
  @moduledoc """
  Parsing and rendering of OCI image references.

  The syntax is `[registry/]repository[:tag][@digest]`, following the same
  resolution rules as docker and podman:

  - the first component only counts as a registry host when it contains a `.`
    or a `:` (or is exactly `localhost`) — otherwise it is a repository path
    component and `docker.io` is the registry,
  - a repository without a `/` refers to the docker hub `library/` namespace
    (`nginx` is `docker.io/library/nginx`),
  - a missing tag defaults to `latest`; a digest pin (`@sha256:<hex>`) can
    accompany a tag or replace it.

  A digest-pinned reference carries `tag: nil` when no tag is given; the
  digest is always preferred when both are present.
  """

  @enforce_keys [:registry, :repository]
  defstruct [:registry, :repository, :tag, :digest]

  @type t :: %__MODULE__{
          registry: String.t(),
          repository: String.t(),
          tag: String.t() | nil,
          digest: String.t() | nil
        }

  @digest_regex ~r/^sha256:[0-9a-f]{64}$/

  @doc """
  Parse an image reference, defaulting the registry to docker.io and the tag
  to `latest` following docker-compatible resolution rules. A digest-pinned
  reference without a tag keeps `tag: nil` — the digest supersedes any tag.
  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(reference) when is_binary(reference) do
    with {:ok, rest, digest} <- split_digest(reference),
         {:ok, repository, tag} <- split_tag(rest, digest),
         {registry, repository} <- split_registry(repository),
         true <- valid_path?(repository) and valid_component?(tag) do
      tag = if digest != nil and tag == "latest", do: nil, else: tag
      {:ok, %__MODULE__{registry: registry, repository: repository, tag: tag, digest: digest}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  defp split_digest(reference) do
    case String.split(reference, "@") do
      [rest] ->
        {:ok, rest, nil}

      [rest, digest] ->
        case Regex.match?(@digest_regex, digest) do
          true -> {:ok, rest, digest}
          false -> :error
        end

      _ ->
        :error
    end
  end

  # The tag, when present, is the part after the colon of the last path
  # component; earlier components may contain colons themselves (registry
  # hosts with ports, `localhost:5000/repo:tag`). A digest pin replaces a
  # defaulted `latest` tag with `nil`.
  defp split_tag(rest, digest) do
    {last, leading} = rest |> String.split("/") |> List.pop_at(-1)

    case String.split(last, ":") do
      # no tag in the last component
      [^last] ->
        {:ok, rest, default_tag(digest)}

      # exactly one colon: the tag is what follows it
      [path, tag] when leading == [] ->
        {:ok, path, tag}

      [path, tag] ->
        {:ok, Path.join(leading ++ [path]), tag}

      # several colons in the last component (`foo:bar:baz`) is not a
      # valid reference
      _ ->
        :error
    end
  end

  defp default_tag(nil), do: "latest"
  defp default_tag(_digest), do: nil

  # The first path component is a registry host when it looks like one
  # (contains a dot or a colon, or is `localhost`); otherwise the whole
  # reference is a repository path resolved against docker.io.
  defp split_registry(repository) do
    case String.split(repository, "/", parts: 2) do
      [single] ->
        {"docker.io", "library/" <> single}

      [first, rest] ->
        if registry_host?(first), do: {first, rest}, else: {"docker.io", repository}
    end
  end

  defp registry_host?(component),
    do: component == "localhost" or String.contains?(component, [".", ":"])

  defp valid_path?(path) do
    path != "" and String.split(path, "/") |> Enum.all?(&valid_component?/1)
  end

  defp valid_component?(nil), do: true

  defp valid_component?(component) do
    component != "" and not String.contains?(component, ["/", ":"])
  end

  @doc """
  Render the canonical fully qualified form `registry/repository[:tag][@digest]`.
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = ref) do
    base = "#{ref.registry}/#{ref.repository}"

    cond do
      ref.digest -> "#{base}@#{ref.digest}"
      ref.tag -> "#{base}:#{ref.tag}"
      true -> base
    end
  end

  # String.Chars implementation, so references interpolate in logs and
  # error messages (`"...#{ref}"`).
  defimpl String.Chars, for: __MODULE__ do
    def to_string(ref), do: @for.to_string(ref)
  end
end
