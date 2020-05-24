defmodule Jocker.CLI.Main do
  import Jocker.CLI.Docs
  import Jocker.Engine.Records
  alias Jocker.CLI.EngineClient
  require Logger

  def main(args) do
    Logger.configure(level: :error)
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
        # TODO: plz2implement
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
        to_cli(image_help(), :eof)

      ["image" | ["--help"]] ->
        to_cli(image_help(), :eof)

      ["image", "build" | opts] ->
        image_build(opts)

      ["image", "ls" | opts] ->
        image_ls(opts)

      ["image", unknown_subcmd | _opts] ->
        to_cli("jocker: '#{unknown_subcmd}' is not a jocker command.", :eof)

      ["container" | []] ->
        to_cli(container_help(), :eof)

      ["container" | ["--help"]] ->
        to_cli(container_help(), :eof)

      ["container", "ls" | opts] ->
        container_ls(opts)

      ["container", "create" | opts] ->
        container_create(opts)

      ["container", "start" | opts] ->
        container_start(opts)

      ["container", unknown_subcmd | _opts] ->
        to_cli("jocker: '#{unknown_subcmd}' is not a jocker command.", :eof)

      ["volume" | []] ->
        to_cli(volume_help(), :eof)

      ["volume" | ["--help"]] ->
        to_cli(volume_help(), :eof)

      ["volume", "ls" | opts] ->
        volume_ls(opts)

      ["volume", "create" | opts] ->
        volume_create(opts)

      ["volume", "rm" | opts] ->
        volume_rm(opts)

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
        {:ok, _pid} = Jocker.CLI.EngineClient.start_link([])
        context = Path.absname(path)
        dockerfile_path = Path.join(context, "Dockerfile")
        tagname = Jocker.Engine.Utils.decode_tagname(Keyword.get(options, :tag, "<none>:<none>"))
        rpc = [Jocker.Engine.Image, :build_image_from_file, [dockerfile_path, tagname, context]]
        _output = EngineClient.command(rpc)
        {:ok, image(id: id)} = fetch_reply()
        to_cli("Image succesfully created with id #{id}", :eof)

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
        {:ok, _pid} = EngineClient.start_link([])
        rpc = [Jocker.Engine.MetaData, :list_images, []]
        _output = EngineClient.command(rpc)
        images = fetch_reply()
        print_image(image(name: "NAME", tag: "TAG", id: "IMAGE ID", created: "CREATED"))
        Enum.map(images, &print_image/1)
        cli_eof()

      {_options, _args} ->
        to_cli("\"jocker image ls\" requires no arguments.")
        to_cli(image_ls_help(), :eof)

      :error ->
        :ok
    end
  end

  defp print_image(image(name: name_, tag: tag_, id: id_, created: timestamp_)) do
    # TODO we need to have a "SIZE" column as the last column
    name = cell(name_, 12)
    tag = cell(tag_, 10)
    id = cell(id_, 12)

    timestamp =
      case timestamp_ do
        "CREATED" -> cell(timestamp_, 12)
        _ -> cell(Jocker.Engine.Utils.human_duration(timestamp_), 12)
      end

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
        rpc = [Jocker.Engine.MetaData, :list_containers, [options]]
        _output = EngineClient.command(rpc)
        containers = fetch_reply()

        print_container(
          container(
            id: "CONTAINER ID",
            image_id: "IMAGE",
            command: ["COMMAND"],
            running: "STATUS",
            created: "CREATED",
            name: "NAME"
          )
        )

        Enum.map(containers, &print_container/1)
        cli_eof()

      {_options, _args} ->
        to_cli("\"jocker image ls\" requires no arguments.")
        to_cli(container_ls_help(), :eof)

      :error ->
        :ok
    end
  end

  def container_create(argv) do
    case process_subcommand(container_create_help(), "container create", argv,
           strict: [
             name: :string,
             help: :boolean
           ]
         ) do
      {_options, []} ->
        to_cli("\"jocker container create\" requires at least 1 argument.")
        to_cli(container_create_help(), :eof)

      {options, [image | cmd]} ->
        opts =
          case length(cmd) do
            0 ->
              [image: image] ++ options

            _n ->
              [cmd: cmd, image: image] ++ options
          end

        {:ok, _pid} = EngineClient.start_link([])
        rpc = [Jocker.Engine.ContainerPool, :create, [opts]]
        :ok = EngineClient.command(rpc)

        case fetch_reply() do
          :image_not_found ->
            to_cli("Unable to find image '#{image}'", :eof)

          {:ok, pid} ->
            rpc2 = [Jocker.Engine.Container, :metadata, [pid]]
            :ok = EngineClient.command(rpc2)
            container(id: id) = fetch_reply()
            to_cli(id, :eof)
        end

      :error ->
        :ok
    end
  end

  def container_start(argv) do
    case process_subcommand(container_start_help(), "container start", argv,
           aliases: [
             a: :attach
           ],
           strict: [
             attach: :boolean,
             help: :boolean
           ]
         ) do
      {_options, []} ->
        to_cli("\"jocker container start\" requires at least 1 argument.")
        to_cli(container_start_help(), :eof)

      {options, containers} ->
        {:ok, _pid} = EngineClient.start_link([])

        case {Keyword.get(options, :attach, false), length(containers)} do
          {false, _} ->
            Enum.map(containers, &start_single_container/1)
            cli_eof()

          {true, 1} ->
            [id_or_name] = containers
            start_single_container(id_or_name, true)
            output_container_messages()
            cli_eof()

          {true, _n} ->
            to_cli("jocker: you cannot start and attach multiple containers at once\n", :eof)
        end

      :error ->
        :ok
    end
  end

  def volume_create(argv) do
    case process_subcommand(volume_create_help(), "volume create", argv,
           strict: [
             help: :boolean
           ]
         ) do
      {_options, args} ->
        case args do
          [] ->
            {:ok, _pid} = EngineClient.start_link([])
            rpc2 = [Jocker.Engine.Volume, :create_volume, []]
            :ok = EngineClient.command(rpc2)
            volume(name: name) = fetch_reply()
            to_cli(name <> "\n", :eof)

          [name] ->
            {:ok, _pid} = EngineClient.start_link([])
            rpc2 = [Jocker.Engine.Volume, :create_volume, [name]]
            :ok = EngineClient.command(rpc2)
            volume(name: name) = fetch_reply()
            to_cli(name <> "\n", :eof)

          _ ->
            to_cli("\"jocker volume create\" requires at most 1 argument.")
            to_cli(volume_create_help(), :eof)
        end

      :error ->
        :ok
    end
  end

  def volume_rm(argv) do
    case process_subcommand(volume_rm_help(), "volume rm", argv,
           strict: [
             help: :boolean
           ]
         ) do
      {_options, args} ->
        case args do
          [] ->
            to_cli("\"jocker volume rm\" requires at least 1 argument.")
            to_cli(volume_rm_help(), :eof)

          volumes ->
            {:ok, _pid} = EngineClient.start_link([])
            Enum.map(volumes, &remove_a_volume/1)
            cli_eof()
        end

      :error ->
        :ok
    end
  end

  defp remove_a_volume(name) do
    :ok = EngineClient.command([Jocker.Engine.MetaData, :get_volume, [name]])

    case fetch_reply() do
      :not_found ->
        to_cli("Error: No such volume: #{name}\n")

      volume ->
        :ok = EngineClient.command([Jocker.Engine.Volume, :delete_volume, [volume]])
        :ok = fetch_reply()
        to_cli("#{name}\n")
    end
  end

  def volume_ls(argv) do
    case process_subcommand(volume_ls_help(), "volume ls", argv,
           aliases: [
             q: :quiet
           ],
           strict: [
             help: :boolean,
             quiet: :boolean
           ]
         ) do
      {options, args} ->
        case args do
          [] ->
            # FIXME: fix support for --quiet
            {:ok, _pid} = EngineClient.start_link([])
            :ok = EngineClient.command([Jocker.Engine.MetaData, :list_volumes, []])
            volumes = fetch_reply()

            case Keyword.get(options, :quiet, false) do
              false ->
                print_volume(["VOLUME NAME", "CREATED"])

                Enum.map(volumes, fn volume(name: name, created: created) ->
                  print_volume([name, created])
                end)

              true ->
                Enum.map(volumes, fn volume(name: name) -> to_cli("#{name}\n") end)
            end

            cli_eof()

          _arguments ->
            to_cli("\"jocker volume ls\" accepts no arguments.")
            to_cli(volume_ls_help(), :eof)
        end

      :error ->
        :ok
    end
  end

  defp print_volume([name, created]) do
    name = cell(name, 14)

    timestamp =
      case created do
        "CREATED" -> cell(created, 18)
        _ -> cell(Jocker.Engine.Utils.human_duration(created), 18)
      end

    n = 3

    to_cli("#{name}#{sp(n)}#{timestamp}\n")
  end

  defp output_container_messages() do
    case fetch_reply() do
      {:container, _pid, {:shutdown, :end_of_ouput}} ->
        to_cli(
          "jocker: primary process terminated but the container is still running in the background"
        )

        :ok

      {:container, _pid, {:shutdown, :jail_stopped}} ->
        :ok

      {:container, _pid, msg} ->
        to_cli(msg)
        output_container_messages()

      unknown_msg ->
        IO.puts(
          "Unknown message received while waiting for container output #{inspect(unknown_msg)}"
        )
    end
  end

  defp start_single_container(id_or_name, attach \\ false) do
    EngineClient.command([
      Jocker.Engine.MetaData,
      :get_container,
      [id_or_name]
    ])

    case fetch_reply() do
      container(id: id) ->
        EngineClient.command([
          Jocker.Engine.ContainerPool,
          :create,
          [[id_or_name: id]]
        ])

        {:ok, pid} = fetch_reply()

        if attach do
          EngineClient.command([
            Jocker.Engine.Container,
            :attach,
            [pid]
          ])

          :ok = fetch_reply()
        end

        EngineClient.command([
          Jocker.Engine.Container,
          :start,
          [pid]
        ])

        :ok = fetch_reply()

        if not attach do
          to_cli("#{id}\n")
        end

      :not_found ->
        to_cli("Error response from daemon: No such container: #{id_or_name}", :eof)
    end
  end

  defp print_container(
         # TODO we need a "PORTS" column showing ports exposed on the container
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
    cmd = cell(Enum.join(cmd_, " "), 23)

    timestamp =
      case timestamp_ do
        "CREATED" -> cell(timestamp_, 12)
        _ -> cell(Jocker.Engine.Utils.human_duration(timestamp_), 12)
      end

    status = cell(status_, 7)
    n = 3

    to_cli(
      "#{id}#{sp(n)}#{img_id}#{sp(n)}#{cmd}#{sp(n)}#{timestamp}#{sp(n)}#{status}#{sp(n)}#{name}\n"
    )
  end

  defp process_subcommand(docs, subcmd, argv, opts) do
    {options, _, _} = output = OptionParser.parse(argv, opts)

    help = Keyword.get(options, :help, false)

    case output do
      {_, _, []} when help ->
        to_cli(docs, :eof)
        :error

      {options, args, []} ->
        {options, args}

      {_, _, [unknown_flag | _rest]} ->
        to_cli("unknown flag: '#{inspect(unknown_flag)}")
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

  defp fetch_reply() do
    receive do
      {:server_reply, reply} ->
        reply

      what ->
        {:error, "ERROR: Unexpected message received from backend: #{inspect(what)}"}
    end
  end

  defp to_cli(msg, eof \\ nil) do
    Process.send(:cli_master, {:msg, msg}, [])

    case eof do
      :eof -> cli_eof()
      nil -> :ok
    end
  end
end
