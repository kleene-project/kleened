defmodule Jocker.CLI.Container do
  alias Jocker.CLI.Utils
  alias Jocker.Engine.Container
  import Utils, only: [cell: 2, sp: 1, to_cli: 1, to_cli: 2, rpc: 2, rpc: 1]
  require Logger

  @doc """

  Usage:  jocker container COMMAND

  Manage containers

  Commands:
    create      Create a new container
    ls          List containers
    rm          Remove one or more containers
    run         Run a command in a new container
    start       Start one or more stopped containers
    stop        Stop one or more running containers

  Run 'jocker container COMMAND --help' for more information on a command.
  """
  def main_docs(), do: @doc

  @doc """

  Usage:  jocker container ls [OPTIONS]

  List containers

  Options:
  -a, --all             Show all containers (default shows just running)
  """
  def ls(:spec) do
    [
      name: "container ls",
      docs: @doc,
      arg_spec: "==0",
      aliases: [a: :all],
      arg_options: [
        all: :boolean,
        help: :boolean
      ]
    ]
  end

  def ls({options, []}) do
    header = %{
      id: "CONTAINER ID",
      image_id: "IMAGE",
      name: "NAME",
      command: "COMMAND",
      running: "STATUS",
      created: "CREATED"
    }

    print_container(header)
    containers_raw = rpc([Jocker.Engine.Container, :list, [options]])

    containers =
      Enum.map(
        containers_raw,
        fn %{
             running: running_boolean,
             command: command_json,
             created: created_iso,
             image_id: img_id,
             image_name: img_name,
             image_tag: img_tag
           } = row ->
          {:ok, command} = Jason.decode(command_json)
          command = Enum.join(command, " ")

          created = Jocker.Engine.Utils.human_duration(created_iso)

          image =
            case img_name do
              "" -> img_id
              _ -> "#{img_name}:#{img_tag}"
            end

          running =
            case running_boolean do
              true -> "running"
              false -> "stopped"
            end

          %{row | image_id: image, running: running, command: command, created: created}
        end
      )

    Enum.map(containers, &print_container/1)
    to_cli(nil, :eof)
  end

  @doc """

  Usage:  jocker container create [OPTIONS] IMAGE [COMMAND] [ARG...]

  Create a new container

  Options:
        --mount.devfs/--no-mount.devfs   Toggle devfs mount (default true)
        --name string                    Assign a name to the container
        --network string                 Connect a container to a network
    -v, --volume                         Bind mount a volume
    -e, --env                            Set environment variables (e.g. --env FIRST=env --env SECOND=env)
    -J, --jailparam string               Specify a jail parameter (see jail(8) for details)

  """
  def create(:spec) do
    [
      name: "container create",
      docs: @doc,
      arg_spec: "=>1",
      aliases: [v: :volume, J: :jailparam],
      arg_options: [
        "mount.devfs": :boolean,
        name: :string,
        network: :string,
        volume: :keep,
        env: :keep,
        jailparam: :keep,
        help: :boolean
      ]
    ]
  end

  def create({options, [image | cmd]}) do
    options = convert_network_option(options)
    {mountdevfs_jailparam, options} = convert_mountdevfs_option(options)

    env_vars =
      Enum.reduce(options, [], fn
        {:env, value}, acc -> [value | acc]
        _other_option, acc -> acc
      end)

    jail_param =
      Enum.reduce(options, [], fn
        {:jailparam, value}, acc -> [value | acc]
        _other_option, acc -> acc
      end)

    jail_param = create_jailparams(mountdevfs_jailparam, jail_param)

    opts =
      case length(cmd) do
        0 ->
          [env: env_vars, image: image, jail_param: jail_param] ++ options

        _n ->
          [cmd: cmd, env: env_vars, image: image, jail_param: jail_param] ++ options
      end

    case rpc([Jocker.Engine.Container, :create, [opts]]) do
      :image_not_found ->
        to_cli("Unable to find image '#{image}'", :eof)

      {:ok, %Container{id: id}} ->
        to_cli("#{id}\n", :eof)

      :tcp_closed ->
        to_cli("Connection closed unexpectedly\n", :eof)
    end
  end

  @doc """

  Usage:	jocker container rm CONTAINER [CONTAINER...]

  Remove one or more containers

  """
  def rm(:spec) do
    [
      name: "container rm",
      docs: @doc,
      arg_spec: "=>1",
      arg_options: [
        help: :boolean
      ]
    ]
  end

  def rm({_options, containers}) do
    :ok = destroy_containers(containers)
    to_cli(nil, :eof)
  end

  @doc """

  Usage:	jocker container start [OPTIONS] CONTAINER [CONTAINER...]

  Start one or more stopped containers

  Options:

      -a, --attach               Attach STDOUT/STDERR

  """
  def start(:spec) do
    [
      name: "container start",
      docs: @doc,
      arg_spec: "=>1",
      aliases: [a: :attach],
      arg_options: [
        attach: :boolean,
        help: :boolean
      ]
    ]
  end

  def start({options, containers}) do
    case {Keyword.get(options, :attach, false), length(containers)} do
      {false, _} ->
        Enum.map(containers, &start_single_container/1)
        to_cli(nil, :eof)

      {true, 1} ->
        [id_or_name] = containers
        {:ok, %Container{id: id}} = start_single_container(id_or_name, true)
        output_container_messages(id)
        :tcp_closed = Utils.fetch_reply()
        to_cli(nil, :eof)

      {true, _n} ->
        to_cli("jocker: you cannot start and attach multiple containers at once\n", :eof)
    end
  end

  defp start_single_container(id_or_name, attach \\ false) do
    if attach do
      case rpc([Jocker.Engine.Container, :attach, [id_or_name]], :async) do
        :ok ->
          rpc([Jocker.Engine.Container, :start, [id_or_name]])

        {:error, :not_found} ->
          to_cli("Error: No such container: #{id_or_name}\n")
      end
    else
      case rpc([Jocker.Engine.Container, :start, [id_or_name]]) do
        {:ok, %Container{id: id}} ->
          to_cli("#{id}\n")

        {:error, :not_found} ->
          to_cli("Error: No such container: #{id_or_name}\n")
      end
    end
  end

  defp output_container_messages(id) do
    case Utils.fetch_reply() do
      {:container, ^id, {:shutdown, :end_of_ouput}} ->
        to_cli(
          "jocker: primary process terminated but the container is still running in the background\n"
        )

        :ok

      {:container, ^id, {:shutdown, :jail_stopped}} ->
        :ok

      {:container, ^id, msg} ->
        to_cli(msg)
        output_container_messages(id)

      :tcp_closed ->
        to_cli("connection closed unexpectedly", :eof)

      unknown_msg ->
        # In the test it receives a :tcp_closed here. Probably from the previous rpc-command?
        Logger.warn("Unknown message received: #{inspect(unknown_msg)}")
    end
  end

  @doc """

  Usage:	jocker container stop CONTAINER [CONTAINER...]

  Stop one or more running containers

  """
  def stop(:spec) do
    [
      name: "container stop",
      docs: @doc,
      arg_spec: "=>1",
      arg_options: [help: :boolean]
    ]
  end

  def stop({_options, containers}) do
    Enum.map(containers, &stop_container/1)
    to_cli(nil, :eof)
  end

  defp stop_container(container_id) do
    case rpc([Jocker.Engine.Container, :stop, [container_id]]) do
      {:ok, %Container{id: id}} ->
        to_cli("#{id}\n")

      {:error, :not_running} ->
        to_cli("Container '#{container_id}' is not running\n")

      {:error, :not_found} ->
        to_cli("Error: No such container: #{container_id}\n")
    end
  end

  defp destroy_containers([container_id | containers]) do
    :ok = rpc([Jocker.Engine.Container, :destroy, [container_id]])
    to_cli("#{container_id}\n")

    destroy_containers(containers)
  end

  defp destroy_containers([]) do
    :ok
  end

  defp convert_network_option(options) do
    {network, new_options} = Keyword.pop(options, :network, "default")
    Keyword.put(new_options, :networks, [network])
  end

  defp convert_mountdevfs_option(options) do
    {jailparam_value, new_options} = Keyword.pop(options, :"mount.devfs", true)

    jail_param =
      case jailparam_value do
        false -> "mount.devfs=false"
        true -> "mount.devfs=true"
      end

    {jail_param, new_options}
  end

  defp create_jailparams(mountdevfs_param, jail_param) do
    if mount_devfs_in(jail_param) do
      jail_param
    else
      [mountdevfs_param | jail_param]
    end
  end

  defp mount_devfs_in(jail_param) do
    Enum.any?(jail_param, fn x ->
      String.starts_with?(x, "mount.devfs")
    end)
  end

  defp print_container(c) do
    line = [
      cell(c.id, 12),
      cell(c.image_id, 25),
      cell(c.command, 23),
      cell(c.created, 18),
      cell(c.running, 7),
      c.name
    ]

    to_cli(Enum.join(line, sp(3)) <> "\n")
  end
end
