defmodule Jocker.CLI.Main do
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
  def main(["--help"]) do
    IO.puts(@doc)
  end

  def main([]) do
    main(["--help"])
  end

  def main(argv) do
    {options, args, invalid} =
      head =
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

    IO.puts("DEBUG: #{inspect(head)}")

    case {options, args, invalid} do
      {_opts, [], []} ->
        # FIXME: imeplement me
        :implement_me

      {[], rest, []} ->
        parse_subcommand(rest)

      {_opts, rest, []} ->
        parse_subcommand(rest)

      {_, _, [unknown_flag | _rest]} ->
        print_error(:unknown_flag, unknown_flag)
    end
  end

  defp parse_subcommand(argv) do
    IO.puts("DEBUG parse_subcommand: #{inspect(argv)}")

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
        print_error(:unknown_subcommand, "image #{unknown_subcmd}")

      ["container" | []] ->
        container_help()

      ["container" | ["--help"]] ->
        container_help()

      ["container", "ls" | opts] ->
        container_ls(opts)

      ["container", "run" | opts] ->
        container_build(opts)

      ["container", unknown_subcmd | _opts] ->
        print_error(:unknown_subcommand, "container #{unknown_subcmd}")

      [unknown_subcmd | _opts] ->
        print_error(:unknown_subcommand, unknown_subcmd)

      _unexpected ->
        IO.puts("Unexpected error occured.")
    end
  end

  @doc """
  Usage:	jocker image COMMAND

  Manage images

  Commands:
    build       Build an image from a Dockerfile
    ls          List images

  Run 'jocker image COMMAND --help' for more information on a command.
  """
  def image_help() do
    IO.puts(@doc)
  end

  @doc """
  Usage:	jocker image build [OPTIONS] PATH

  Build an image from a Dockerfile

  Options:
  -t, --tag list                Name and optionally a tag in the 'name:tag' format
  """
  def image_build(argv) do
    case process_subcommand(@doc, "image build", argv,
           aliases: [t: :tag],
           strict: [
             tag: :string,
             help: :boolean
           ]
         ) do
      {options, [path]} ->
        # FIXME we need tag-parser and constructing a real command for the backend:
        tag = Keyword.get(options, :tag, "<none>:<none>")
        IO.puts("COMMAND: image build -t #{tag} #{path}")

      {_options, []} ->
        IO.puts("\"jocker image build\" requires exactly 1 argument.")
        IO.puts(@doc)
        :error

      :error ->
        :ok
    end
  end

  @doc """

  Usage:	docker image ls [OPTIONS]

  List images

  Options:
    -a, --all             Show all images (default hides intermediate images)
  """
  def image_ls(argv) do
    case process_subcommand(@doc, "image ls", argv,
           aliases: [a: :all],
           strict: [
             all: :boolean,
             help: :boolean
           ]
         ) do
      {options, []} ->
        cmd =
          case Keyword.get(options, :all, false) do
            true -> "image ls --all"
            false -> "image ls"
          end

        IO.puts("COMMAND: " <> cmd)

      {_options, _args} ->
        IO.puts("\"jocker image ls\" requires no arguments.")
        IO.puts(@doc)

      :error ->
        :ok
    end
  end

  @doc """
  Usage:  docker container COMMAND

  Manage containers

  Commands:
    ls          List containers
    run         Run a command in a new container

  Run 'docker container COMMAND --help' for more information on a command.
  """
  def container_help() do
    IO.puts(@doc)
  end

  # FIXME implement these two functions
  defp container_ls(_opts) do
  end

  defp container_build(_opts) do
  end

  defp process_subcommand(docs, subcmd, argv, opts) do
    {options, _, _} = output = OptionParser.parse(argv, opts)

    IO.puts("DEBUG #{subcmd}: #{inspect(output)}")
    help = Keyword.get(options, :help, false)

    case output do
      {_, _, []} when help ->
        IO.puts(docs)
        :error

      {options, args, []} ->
        {options, args}

      {_, _, [unknown_flag | _rest]} ->
        print_error(:unknown_flag, unknown_flag)
        IO.puts("See '#{subcmd} --help'")
        :error
    end
  end

  defp print_error(:unknown_flag, unknown_flag) do
    IO.puts("unknown flag: '#{unknown_flag}\nSee 'jocker --help'.")
  end

  defp print_error(:unknown_subcommand, subcmd) do
    IO.puts("jocker: '#{subcmd}' is not a jocker command.")
  end
end
