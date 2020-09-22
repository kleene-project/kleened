defmodule Jocker.CLI.Image do
  alias Jocker.CLI.Utils
  import Utils, only: [cell: 2, sp: 1, to_cli: 1, to_cli: 2, rpc: 1]
  import Jocker.Engine.Records

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
  -t, --tag list                Name and optionally a tag in the 'name:tag' format
  """
  def build(:spec) do
    [
      name: "image build",
      docs: @doc,
      arg_spec: "==1",
      aliases: [t: :tag],
      arg_options: [
        tag: :string,
        help: :boolean
      ]
    ]
  end

  def build({options, [path]}) do
    context = Path.absname(path)
    dockerfile_path = Path.join(context, "Dockerfile")
    tagname = Jocker.Engine.Utils.decode_tagname(Keyword.get(options, :tag, "<none>:<none>"))

    {:ok, image(id: id)} =
      rpc([Jocker.Engine.Image, :build_image_from_file, [dockerfile_path, tagname, context]])

    to_cli("Image succesfully created with id #{id}\n", :eof)
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
    print_image(image(name: "NAME", tag: "TAG", id: "IMAGE ID", created: "CREATED"))
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

  defp print_image(image(name: name_, tag: tag_, id: id_, created: created)) do
    # TODO we need to have a "SIZE" column as the last column
    name = cell(name_, 12)
    tag = cell(tag_, 10)
    id = cell(id_, 12)
    timestamp = Utils.format_timestamp(created)

    n = 3
    to_cli("#{name}#{sp(n)}#{tag}#{sp(n)}#{id}#{sp(n)}#{timestamp}\n")
  end
end
