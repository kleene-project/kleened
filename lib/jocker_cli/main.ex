defmodule Jocker.CLI.Main do
  import Jocker.CLI.Docs
  import Jocker.Engine.Records
  alias Jocker.CLI.EngineClient

  def main(args) do
    Process.register(self(), :cli_master)
    spawn_link(__MODULE__, :main_, [args])
    print_output()
  end

  def main_([]) do
    main_(["--help"])
  end

  def main_(["--help"]) do
    to_cli(main_help(), :eof)
  end

  def main_(argv) do
    {options, args, invalid} =
      OptionParser.parse_head(argv,
        aliases: [
          D: :debug,
          v: :version
        ],
        strict: [
          version: :boolean,
          debug: :boolean,
          help: :boolean
        ]
      )

    case {options, args, invalid} do
      {_opts, [], []} ->
        # FIXME: plz2implement
        :implement_me

      {[], rest, []} ->
        parse_subcommand(rest)

      {_opts, rest, []} ->
        parse_subcommand(rest)

      {_, _, [unknown_flag | _rest]} ->
        to_cli("unknown flag: '#{unknown_flag}")
        to_cli("See 'jocker --help'", :eof)
    end
  end

  defp parse_subcommand(argv) do
    case argv do
      ["image" | []] ->
        image_help()

      ["image" | ["--help"]] ->
        image_help()

      ["image", "build" | opts] ->
        image_build(opts)

      ["image", "ls" | opts] ->
        image_ls(opts)

      ["image", unknown_subcmd | _opts] ->
        to_cli("jocker: '#{unknown_subcmd}' is not a jocker command.", :eof)

      ["container" | []] ->
        container_help()

      ["container" | ["--help"]] ->
        container_help()

      ["container", "ls" | opts] ->
        container_ls(opts)

      ["container", "run" | opts] ->
        container_build(opts)

      ["container", unknown_subcmd | _opts] ->
        to_cli("jocker: '#{unknown_subcmd}' is not a jocker command.", :eof)

      [unknown_subcmd | _opts] ->
        to_cli("jocker: '#{unknown_subcmd}' is not a jocker command.", :eof)

      _unexpected ->
        to_cli("Unexpected error occured.", :eof)
    end
  end

  def image_build(argv) do
    case process_subcommand(image_build_help(), "image build", argv,
           aliases: [t: :tag],
           strict: [
             tag: :string,
             help: :boolean
           ]
         ) do
      {options, [path]} ->
        context = Path.absname(path)
        dockerfile_path = Path.join(context, "Dockerfile")
        tagname = Jocker.Engine.Utils.decode_tagname(Keyword.get(options, :tag, "<none>:<none>"))
        rpc = [Jocker.Engine.Image, :build_image_from_file, [dockerfile_path, tagname, context]]
        _output = EngineClient.command(rpc)

        receive do
          {:server_reply, {:ok, image(id: id)}} ->
            to_cli("Image succesfully created with id #{id}", :eof)

          what ->
            IO.puts("ERROR: Unexpected message received from backend: #{inspect(what)}")
        end

      {_options, []} ->
        to_cli("\"jocker image build\" requires exactly 1 argument.")
        to_cli(image_build_help(), :eof)
        :error

      :error ->
        :ok
    end
  end

  def image_ls(argv) do
    case process_subcommand(image_ls_help(), "image ls", argv,
           strict: [
             help: :boolean
           ]
         ) do
      {_options, []} ->
        rpc = [Jocker.Engine.MetaData, :list_images, []]
        {:ok, _pid} = EngineClient.start_link([])
        _output = EngineClient.command(rpc)

        receive do
          {:server_reply, images} ->
            print_image(image(name: "NAME", tag: "TAG", id: "IMAGE ID", created: "CREATED"))
            Enum.map(images, &print_image/1)
            cli_eof()

          what ->
            IO.puts("ERROR: Unexpected message received from backend: #{inspect(what)}")
        end

      {_options, _args} ->
        to_cli("\"jocker image ls\" requires no arguments.")
        to_cli(image_ls_help(), :eof)

      :error ->
        :ok
    end
  end

  defp print_image(image(name: name_, tag: tag_, id: id_, created: timestamp_)) do
    # FIXME we need to have a "SIZE" column as the last column
    name = cell(name_, 12)
    tag = cell(tag_, 10)
    id = cell(id_, 12)
    timestamp = cell(timestamp_, 16)
    n = 3
    to_cli("#{name}#{sp(n)}#{tag}#{sp(n)}#{id}#{sp(n)}#{timestamp}\n")
  end

  def container_ls(argv) do
    case process_subcommand(container_ls_help(), "image ls", argv,
           aliases: [a: :all],
           strict: [
             all: :boolean,
             help: :boolean
           ]
         ) do
      {options, []} ->
        {:ok, _pid} = EngineClient.start_link([])
        all = Keyword.get(options, :all, false)
        rpc = [Jocker.Engine.MetaData, :list_containers, [[{:all, all}]]]
        _output = EngineClient.command(rpc)

        receive do
          {:server_reply, containers} ->
            print_container(
              container(
                id: "CONTAINER ID",
                image_id: "IMAGE",
                command: "COMMAND",
                running: "STATUS",
                created: "CREATED",
                name: "NAME"
              )
            )

            Enum.map(containers, &print_container/1)
            cli_eof()

          what ->
            IO.puts("ERROR: Unexpected message received from backend: #{inspect(what)}")
        end

      {_options, _args} ->
        to_cli("\"jocker image ls\" requires no arguments.")
        to_cli(container_ls_help(), :eof)

      :error ->
        :ok
    end
  end

  defp print_container(
         # FIXME we need a "PORTS" column showing ports exposed on the container
         container(
           id: id_,
           image_id: img_id_,
           name: name,
           command: cmd_,
           running: running,
           created: timestamp_
         )
       ) do
    status_ =
      case running do
        true -> "running"
        false -> "stopped"
        other -> other
      end

    id = cell(id_, 12)
    img_id = cell(img_id_, 25)
    cmd = cell(cmd_, 23)
    timestamp = cell(timestamp_, 16)
    status = cell(status_, 7)
    n = 3

    to_cli(
      "#{id}#{sp(n)}#{img_id}#{sp(n)}#{cmd}#{sp(n)}#{timestamp}#{sp(n)}#{status}#{sp(n)}#{name}\n"
    )
  end

  defp container_build(_opts) do
  end

  defp process_subcommand(docs, subcmd, argv, opts) do
    {options, _, _} = output = OptionParser.parse(argv, opts)

    # IO.puts("DEBUG #{subcmd}: #{inspect(output)}")
    help = Keyword.get(options, :help, false)

    case output do
      {_, _, []} when help ->
        IO.puts(docs)
        :error

      {options, args, []} ->
        {options, args}

      {_, _, [unknown_flag | _rest]} ->
        to_cli("unknown flag: '#{unknown_flag}")
        to_cli("See '#{subcmd} --help'", :eof)
        :error
    end
  end

  defp cell(content, size) do
    content_length = String.length(content)

    case content_length < size do
      true -> content <> sp(size - content_length)
      false -> String.slice(content, 0, size)
    end
  end

  defp sp(n) do
    String.pad_trailing(" ", n)
  end

  defp print_output() do
    receive do
      {:msg, :eof} ->
        :ok

      {:msg, msg} ->
        IO.puts(msg)
        print_output()

      unknown_message ->
        exit({:error, "Unexpected cli output: #{inspect(unknown_message)}"})
    end
  end

  defp cli_eof() do
    Process.send(:cli_master, {:msg, :eof}, [])
  end

  defp to_cli(msg, eof \\ nil) do
    Process.send(:cli_master, {:msg, msg}, [])

    case eof do
      :eof -> cli_eof()
      nil -> :ok
    end
  end
end
