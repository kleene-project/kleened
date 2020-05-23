defmodule CLITest do
  use ExUnit.Case
  require Jocker.Engine.Config
  import Jocker.Engine.Records

  @moduletag :capture_log

  setup_all do
    Application.stop(:jocker)
    Jocker.Engine.ZFS.clear_zroot()
    start_supervised({Jocker.Engine.MetaData, [file: Jocker.Engine.Config.metadata_db()]})
    start_supervised(Jocker.Engine.Layer)
    start_supervised({Jocker.Engine.Network, [{"10.13.37.1", "10.13.37.255"}, "jocker0"]})
    start_supervised(Jocker.Engine.ContainerPool)
    start_supervised(Jocker.Engine.APIServer)
    :ok
  end

  setup do
    Process.register(self(), :cli_master)
    Jocker.Engine.MetaData.clear_tables()
    :ok
  end

  test "escript main help" do
    {output, 0} = exec_jocker([])
    assert "\nUsage:\tjocker [OPTIONS] COMMAND" == String.slice(output, 0, 32)
  end

  test "api_server image ls" do
    {:ok, _pid} = Jocker.CLI.EngineClient.start_link([])
    rpc = [Jocker.Engine.MetaData, :list_images, []]
    :ok = Jocker.CLI.EngineClient.command(rpc)

    receive do
      {:server_reply, reply} ->
        assert [] == reply
    end
  end

  test "jocker <no arguments or options>" do
    [msg] = jocker_cmd([])
    assert "\nUsage:\tjocker [OPTIONS] COMMAND" == String.slice(msg, 0, 32)
  end

  test "jocker image ls <irrelevant argument>" do
    [msg1, _] = jocker_cmd(["image", "ls", "irrelevant_argument"])
    assert "\"jocker image ls\" requires no arguments." == msg1
  end

  test "jocker image ls" do
    img =
      image(
        id: "test-image-id",
        name: "test-image",
        tag: "latest",
        command: "/bin/ls",
        created: DateTime.to_iso8601(DateTime.from_unix!(1))
      )

    Jocker.Engine.MetaData.add_image(img)

    [msg1, msg2] = jocker_cmd(["image", "ls"])
    assert "NAME           TAG          IMAGE ID       CREATED     \n" == msg1
    assert "test-image     latest       test-image-i   50 years    \n" == msg2
  end

  test "jocker image build" do
    path = "./test/data/test_cli_build_image"

    [msg1] = jocker_cmd(["image", "build", "-t", "lol:test", path])
    id1 = String.slice(msg1, 34, 12)
    assert image(name: "lol", tag: "test") = Jocker.Engine.MetaData.get_image(id1)

    [msg2] = jocker_cmd(["image", "build", path])
    id2 = String.slice(msg2, 34, 12)
    assert image(name: "<none>", tag: "<none>") = Jocker.Engine.MetaData.get_image(id2)
  end

  test "jocker container ls" do
    container =
      container(
        id: "testing-id-truncatethis",
        name: "testname",
        ip: Jocker.Engine.Network.new(),
        command: ["/bin/ls"],
        image_id: "base",
        created: DateTime.to_iso8601(DateTime.from_unix!(1))
      )

    Jocker.Engine.MetaData.add_container(container)
    [msg1] = jocker_cmd(["container", "ls"])

    header =
      "CONTAINER ID   IMAGE                       COMMAND                   CREATED        STATUS    NAME\n"

    assert msg1 == header

    [msg2, msg3] = jocker_cmd(["container", "ls", "-a"])

    assert msg2 == header

    assert msg3 ==
             "testing-id-t   base                        /bin/ls                   50 years       stopped   testname\n"
  end

  test "jocker container create" do
    [id] = jocker_cmd(["container", "create", "base"])
    containers = Jocker.Engine.MetaData.list_containers(all: true)
    assert [container(id: ^id)] = containers

    [id2] = jocker_cmd(["container", "create", "--name", "loltest", "base"])
    containers2 = Jocker.Engine.MetaData.list_containers(all: true)
    assert [container(id: ^id2, name: "loltest") | _] = containers2
  end

  test "jocker container start" do
    {:ok, pid} = Jocker.Engine.Container.create(image: "base", cmd: ["/bin/sleep", "10000"])
    container(id: id) = Jocker.Engine.Container.metadata(pid)

    assert [container(id: ^id, running: false)] =
             Jocker.Engine.MetaData.list_containers(all: true)

    assert ["#{id}\n"] == jocker_cmd(["container", "start", id])
    assert [container(id: ^id, running: true)] = Jocker.Engine.MetaData.list_containers(all: true)
    Jocker.Engine.Container.stop(pid)

    assert [container(id: ^id, running: false)] =
             Jocker.Engine.MetaData.list_containers(all: true)
  end

  test "jocker container start --attach" do
    {:ok, pid} = Jocker.Engine.Container.create(image: "base", cmd: ["/bin/sh", "-c", "echo lol"])
    container(id: id) = Jocker.Engine.Container.metadata(pid)
    Jocker.Engine.Container.stop(pid)
    assert ["lol\n"] == jocker_cmd(["container", "start", "-a", id])
  end

  defp jocker_cmd(command) do
    spawn_link(Jocker.CLI.Main, :main_, [command])
    output = collect_output([])
    stop_client()
    output
  end

  defp stop_client() do
    if is_client_alive?() do
      GenServer.stop(Jocker.CLI.EngineClient)
    end
  end

  defp is_client_alive?() do
    case Enum.find(Process.registered(), fn x -> x == Jocker.CLI.EngineClient end) do
      Jocker.CLI.EngineClient -> true
      nil -> false
    end
  end

  defp collect_output(output) do
    receive do
      {:msg, :eof} ->
        Enum.reverse(output)

      {:msg, msg} ->
        collect_output([msg | output])

      other ->
        IO.puts("Unexpected message received while waiting for cli-messages: #{inspect(other)}")
        exit(:shutdown)
    end
  end

  defp exec_jocker(args) do
    {:ok, path} = File.cwd()
    System.cmd("#{path}/jocker", args)
  end
end
