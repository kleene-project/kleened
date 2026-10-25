defmodule Kleened.OCIRefTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Kleened.Core.OCI.Ref

  test "parses a fully qualified reference with registry, repository and tag" do
    assert {:ok,
            %Ref{
              registry: "ghcr.io",
              repository: "freebsd/freebsd-runtime",
              tag: "15.0",
              digest: nil
            }} = Ref.parse("ghcr.io/freebsd/freebsd-runtime:15.0")
  end

  test "parses a fully qualified reference without a tag, defaulting the tag to latest" do
    assert {:ok, %Ref{registry: "ghcr.io", repository: "freebsd/freebsd-runtime", tag: "latest"}} =
             Ref.parse("ghcr.io/freebsd/freebsd-runtime")
  end

  test "parses a reference with a port in the registry host" do
    assert {:ok, %Ref{registry: "localhost:5000", repository: "myimage", tag: "v1"}} =
             Ref.parse("localhost:5000/myimage:v1")
  end

  test "a two-component name is a docker.io org repo" do
    assert {:ok, %Ref{registry: "docker.io", repository: "freebsd/freebsd-static", tag: "15.0"}} =
             Ref.parse("freebsd/freebsd-static:15.0")
  end

  test "a single name is a docker.io library repo" do
    assert {:ok, %Ref{registry: "docker.io", repository: "library/nginx", tag: "1.27"}} =
             Ref.parse("nginx:1.27")
  end

  test "an untagged single name gets the latest tag" do
    assert {:ok, %Ref{registry: "docker.io", repository: "library/nginx", tag: "latest"}} =
             Ref.parse("nginx")
  end

  test "parses a digest-pinned reference" do
    digest = "sha256:365b63f478896c17c070a86977edce07bded4cd0baeafd4bd8bb4cfeec81bfe2"

    assert {:ok,
            %Ref{
              registry: "ghcr.io",
              repository: "freebsd/freebsd-static",
              tag: nil,
              digest: ^digest
            }} =
             Ref.parse("ghcr.io/freebsd/freebsd-static@" <> digest)
  end

  test "keeps the tag alongside a digest pin" do
    digest = "sha256:365b63f478896c17c070a86977edce07bded4cd0baeafd4bd8bb4cfeec81bfe2"

    assert {:ok, %Ref{tag: "15.0", digest: ^digest}} =
             Ref.parse("freebsd/freebsd-static:15.0@" <> digest)
  end

  test "rejects an invalid digest" do
    assert :error = Ref.parse("freebsd/freebsd-static@sha256:tooshort")

    assert :error =
             Ref.parse(
               "freebsd/freebsd-static@md5:365b63f478896c17c070a86977edce07bded4cd0baeafd4bd8bb4cfeec81bfe2"
             )
  end

  test "rejects garbage" do
    assert :error = Ref.parse("")
    assert :error = Ref.parse(":")
    assert :error = Ref.parse("foo:bar:baz")

    assert :error =
             Ref.parse("@sha256:365b63f478896c17c070a86977edce07bded4cd0baeafd4bd8bb4cfeec81bfe2")
  end

  test "rejects empty components" do
    assert :error = Ref.parse("/freebsd")
    assert :error = Ref.parse("freebsd/")
    assert :error = Ref.parse("freebsd//static")
  end

  test "renders the canonical fully qualified form" do
    {:ok, ref} = Ref.parse("freebsd/freebsd-static:15.0")
    assert "docker.io/freebsd/freebsd-static:15.0" == Ref.to_string(ref)

    {:ok, ref} = Ref.parse("nginx")
    assert "docker.io/library/nginx:latest" == Ref.to_string(ref)

    digest = "sha256:365b63f478896c17c070a86977edce07bded4cd0baeafd4bd8bb4cfeec81bfe2"
    {:ok, ref} = Ref.parse("ghcr.io/freebsd/freebsd-static@" <> digest)
    assert "ghcr.io/freebsd/freebsd-static@" <> digest == Ref.to_string(ref)
  end

  test "to_string/1 implements the String.Chars protocol" do
    {:ok, ref} = Ref.parse("freebsd/freebsd-static:15.0")
    assert "docker.io/freebsd/freebsd-static:15.0" == to_string(ref)
  end
end
