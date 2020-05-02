defmodule Jocker.CLI.Docs do
  @moduledoc """
  Documentation for the CLI-interface of jocker.
  """

  @doc """

  Usage:	jocker [OPTIONS] COMMAND

  A self-sufficient runtime for containers

  Options:
  -D, --debug              Enable debug mode
  -v, --version            Print version information and quit

  Management Commands:
  container   Manage containers
  image       Manage images

  Run 'jocker COMMAND --help' for more information on a command.
  """
  def main_help(), do: @doc

  @doc """

  Usage:	jocker image COMMAND

  Manage images

  Commands:
    build       Build an image from a Dockerfile
    ls          List images

  Run 'jocker image COMMAND --help' for more information on a command.
  """
  def image_help(), do: @doc

  @doc """

  Usage:	jocker image build [OPTIONS] PATH

  Build an image from a Dockerfile

  Options:
  -t, --tag list                Name and optionally a tag in the 'name:tag' format
  """
  def image_build_help(), do: @doc

  @doc """

  Usage:	jocker image ls

  List images

  """
  def image_ls_help(), do: @doc

  @doc """

  Usage:  jocker container COMMAND

  Manage containers

  Commands:
    ls          List containers
    run         Run a command in a new container

  Run 'docker container COMMAND --help' for more information on a command.
  """
  def container_help(), do: @doc

  @doc """

  Usage:  docker container create [OPTIONS] IMAGE [COMMAND] [ARG...]

  Create a new container

  Options:
        --name string                    Assign a name to the container

  """
  def container_create_help(), do: @doc

  @doc """

  Usage:  docker container ls [OPTIONS]

  List containers

  Options:
  -a, --all             Show all containers (default shows just running)
  """
  def container_ls_help(), do: @doc
end
