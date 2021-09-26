defmodule Jocker.CLI.Main do
  import Jocker.CLI.Docs
  alias Jocker.CLI.Utils
  import Utils, only: [to_cli: 1, to_cli: 2]
  require Logger

  @cli_version "0.0.1"
  def main(args) do
    Logger.configure(level: :error)
    Process.register(self(), :cli_master)
    spawn_link(__MODULE__, :main_, [args])
    print_output()
  end

  @doc """

  Usage:  jocker [OPTIONS] COMMAND

  A self-sufficient runtime for containers

  Options:
  -v, --version            Print version information and quit
  -D, --debug              Enable debug mode
  -H, --host string        Daemon socket to connect to: tcp://[host]:[port][path] or unix://[/path/to/socket]

  Management Commands:
  container   Manage containers
  image       Manage images
  network     Manage networks
  volume      Manage volumes

  Run 'jocker COMMAND --help' for more information on a command.
  """
  def main_(args) when args == [] or args == ["--help"] do
    to_cli(@doc, :eof)
  end

  def main_(argv) do
    {options, args, invalid} =
      OptionParser.parse_head(argv,
        aliases: [
          v: :version,
          H: :host,
          D: :debug
        ],
        strict: [
          debug: :boolean,
          version: :boolean,
          host: :string,
          help: :boolean
        ]
      )

    case {options, args, invalid} do
      {opts, [], []} ->
        perhaps_print_version(opts)

      {[], rest, []} ->
        Jocker.CLI.Config.start_link([:default])
        parse_subcommand(rest)

      {opts, rest, []} ->
        cond do
          Keyword.get(opts, :debug) -> Logger.configure(level: :debug)
        end

        Jocker.CLI.Config.start_link(opts)
        parse_subcommand(rest)

      {_, _, [unknown_flag | _rest]} ->
        to_cli("unknown flag: '#{unknown_flag}'")
        to_cli("See 'jocker --help'", :eof)
    end
  end

  defp perhaps_print_version(opts) do
    case Keyword.get(opts, :version) do
      true -> to_cli("Jocker version #{@cli_version}", :eof)
      _ -> to_cli(nil, :eof)
    end
  end

  defp parse_subcommand(argv) do
    case argv do
      ["image" | subcmd] when subcmd == [] or subcmd == ["--help"] ->
        to_cli(Jocker.CLI.Image.main_docs(), :eof)

      ["image", "build" | opts] ->
        process_subcommand(&Jocker.CLI.Image.build/1, opts)

      ["image", "ls" | opts] ->
        process_subcommand(&Jocker.CLI.Image.ls/1, opts)

      ["image", "rm" | opts] ->
        process_subcommand(&Jocker.CLI.Image.rm/1, opts)

      ["image", unknown_subcmd | _opts] ->
        to_cli("jocker: 'image #{unknown_subcmd}' is not a jocker command.\n")
        to_cli(Jocker.CLI.Image.main_docs(), :eof)

      ["container" | subcmd] when subcmd == [] or subcmd == ["--help"] ->
        to_cli(Jocker.CLI.Container.main_docs(), :eof)

      ["container", "ls" | opts] ->
        process_subcommand(&Jocker.CLI.Container.ls/1, opts)

      ["container", "create" | opts] ->
        process_subcommand(&Jocker.CLI.Container.create/1, opts)

      ["container", "rm" | opts] ->
        process_subcommand(&Jocker.CLI.Container.rm/1, opts)

      ["container", "start" | opts] ->
        process_subcommand(&Jocker.CLI.Container.start/1, opts)

      ["container", "stop" | opts] ->
        process_subcommand(&Jocker.CLI.Container.stop/1, opts)

      ["container", unknown_subcmd | _opts] ->
        to_cli("jocker: 'container #{unknown_subcmd}' is not a jocker command.\n")
        to_cli(Jocker.CLI.Container.main_docs(), :eof)

      ["network" | subcmd] when subcmd == [] or subcmd == ["--help"] ->
        to_cli(Jocker.CLI.Network.main_docs(), :eof)

      ["network", "ls" | opts] ->
        process_subcommand(&Jocker.CLI.Network.ls/1, opts)

      ["network", "create" | opts] ->
        process_subcommand(&Jocker.CLI.Network.create/1, opts)

      ["network", "rm" | opts] ->
        process_subcommand(&Jocker.CLI.Network.rm/1, opts)

      ["network", "connect" | opts] ->
        process_subcommand(&Jocker.CLI.Network.connect/1, opts)

      ["network", "disconnect" | opts] ->
        process_subcommand(&Jocker.CLI.Network.disconnect/1, opts)

      ["network", unknown_subcmd | _opts] ->
        to_cli("jocker: 'network #{unknown_subcmd}' is not a jocker command.\n")
        to_cli(Jocker.CLI.Network.main_docs(), :eof)

      ["volume" | subcmd] when subcmd == [] or subcmd == ["--help"] ->
        to_cli(Jocker.CLI.Volume.main_docs(), :eof)

      ["volume", "ls" | opts] ->
        process_subcommand(&Jocker.CLI.Volume.ls/1, opts)

      ["volume", "create" | opts] ->
        process_subcommand(&Jocker.CLI.Volume.create/1, opts)

      ["volume", "rm" | opts] ->
        process_subcommand(&Jocker.CLI.Volume.rm/1, opts)

      [unknown_cmd | _opts] ->
        to_cli("jocker: '#{unknown_cmd}' is not a jocker command.\n", :eof)

      _unexpected ->
        to_cli("Unexpected error occured.", :eof)
    end
  end

  def process_subcommand(command, argv) do
    spec = command.(:spec)
    cmd_name = Keyword.get(spec, :name)
    docs = Keyword.get(spec, :docs)
    arg_spec = Keyword.get(spec, :arg_spec)
    options = Keyword.get(spec, :arg_options)
    aliases = Keyword.get(spec, :aliases, [])

    args =
      decode_args(docs, cmd_name, argv,
        aliases: aliases,
        strict: options
      )

    case {arg_spec, args} do
      {_, :error} ->
        :ok

      {"==0", {_opts, args}} when length(args) != 0 ->
        to_cli("\"jocker #{cmd_name}\" requires no arguments.")
        to_cli(docs, :eof)
        :error

      {"==1", {_opts, args}} when length(args) != 1 ->
        to_cli("\"jocker #{cmd_name}\" requires exactly 1 argument.\n")
        to_cli(docs, :eof)
        :error

      {"==2", {_opts, args}} when length(args) != 2 ->
        to_cli("\"jocker #{cmd_name}\" requires exactly 2 arguments.\n")
        to_cli(docs, :eof)
        :error

      {"=>1", {_opts, args}} when length(args) < 1 ->
        to_cli("\"jocker #{cmd_name}\" requires at least 1 argument.\n")
        to_cli(docs, :eof)

      {"==0 or ==1", {_opts, args}} when length(args) != 0 and length(args) != 1 ->
        to_cli("\"jocker #{cmd_name}\" requires at most 1 argument.")
        to_cli(docs, :eof)

      {_, opt_args} ->
        command.(opt_args)
        :ok
    end
  end

  defp decode_args(docs, subcmd, argv, opts) do
    {options, _, _} =
      output =
      case subcmd do
        "container create" ->
          OptionParser.parse_head(argv, opts)

        _ ->
          OptionParser.parse(argv, opts)
      end

    help = Keyword.get(options, :help, false)

    case output do
      {_, _, []} when help ->
        to_cli(docs, :eof)
        :error

      {options, args, []} ->
        {options, args}

      {_, _, [{flag, nil} | _rest]} ->
        to_cli("unknown flag: #{inspect(flag)}\n")
        to_cli("See 'jocker #{subcmd} --help'\n", :eof)
        :error

      {_, _, [unknown_flag | _rest]} ->
        to_cli("unknown flag: #{inspect(unknown_flag)}\n")
        to_cli("See 'jocker #{subcmd} --help'\n", :eof)
        :error
    end
  end

  defp print_output() do
    receive do
      {:msg, :eof} ->
        :ok

      {:msg, msg} ->
        IO.write(msg)
        print_output()

      unknown_message ->
        exit({:error, "Unexpected cli output: #{inspect(unknown_message)}"})
    end
  end
end
