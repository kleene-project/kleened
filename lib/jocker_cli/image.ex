defmodule Jocker.CLI.Image do
  alias Jocker.CLI.Utils
  alias Jocker.Engine.Image
  import Utils, only: [cell: 2, sp: 1, to_cli: 1, to_cli: 2, rpc: 2, rpc: 1]
  require Logger

  @doc """

  Usage:	jocker image COMMAND

  Manage images

  Commands:
    build       Build an image from a Dockerfile
    ls          List images
    rm          Remove one or more images

  Run 'jocker image COMMAND --help' for more information on a command.
  """
  def main_docs(), do: @doc

  @doc """

  Usage:	jocker image build [OPTIONS] PATH

  Build an image from a Dockerfile

  Options:
  -t, --tag string              Name and optionally a tag in the 'name:tag' format
  -f, --file string             Name of the Dockerfile (Default is 'PATH/Dockerfile')
  -q, --quiet                   Suppress the build output and print image ID on success
  """
  def build(:spec) do
    [
      name: "image build",
      docs: @doc,
      arg_spec: "==1",
      aliases: [t: :tag, f: :file, q: :quiet],
      arg_options: [
        tag: :string,
        file: :string,
        quiet: :boolean,
        help: :boolean
      ]
    ]
  end

  def build({options, [path]}) do
    path = Path.absname(path)
    tag = Keyword.get(options, :tag, "<none>:<none>")
    quiet = Keyword.get(options, :quiet, false)
    dockerfile = Keyword.get(options, :file, "Dockerfile")
    {:ok, _pid} = rpc([Jocker.Engine.Image, :build, [path, dockerfile, tag, quiet]], :async)
    receive_results()
    :tcp_closed = Utils.fetch_reply()
  end

  defp receive_results() do
    case Utils.fetch_reply() do
      {:image_builder, _pid, {:image_finished, %Image{id: id}}} ->
        to_cli("Image succesfully created with id #{id}\n", :eof)

      {:image_builder, _pid, msg} ->
        to_cli(msg)
        receive_results()

      :tcp_closed ->
        to_cli("connection closed unexpectedly", :eof)

      unknown_msg ->
        Logger.warn("Unexpected message received: #{inspect(unknown_msg)}")
    end
  end

  @doc """

  Usage:	jocker image ls

  List images

  """
  def ls(:spec) do
    [
      name: "image ls",
      docs: @doc,
      arg_spec: "==0",
      arg_options: [
        help: :boolean
      ]
    ]
  end

  def ls({_options, []}) do
    images = rpc([Jocker.Engine.MetaData, :list_images, []])
    print_image(%Image{name: "NAME", tag: "TAG", id: "IMAGE ID", created: "CREATED"})
    Enum.map(images, &print_image/1)
    to_cli(nil, :eof)
  end

  @doc """

  Usage:	jocker image rm [OPTIONS] IMAGE [IMAGE...]

  Remove one or more images
  """
  def rm(:spec) do
    [
      name: "image rm",
      docs: @doc,
      arg_spec: "=>1",
      arg_options: [help: :boolean]
    ]
  end

  def rm({_options, images}) do
    Enum.map(images, fn image_id ->
      case rpc([Jocker.Engine.Image, :destroy, [image_id]]) do
        :ok ->
          to_cli("#{image_id}\n")

        :not_found ->
          to_cli("Error: No such image: #{image_id}\n")
      end
    end)

    to_cli(nil, :eof)
  end

  defp print_image(%Image{name: name_, tag: tag_, id: id_, created: created}) do
    # TODO we need to have a "SIZE" column as the last column
    name = cell(name_, 12)
    tag = cell(tag_, 10)
    id = cell(id_, 12)
    timestamp = Utils.format_timestamp(created)

    n = 3
    to_cli("#{name}#{sp(n)}#{tag}#{sp(n)}#{id}#{sp(n)}#{timestamp}\n")
  end
end
