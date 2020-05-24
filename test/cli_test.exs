defmodule CLITest do
  use ExUnit.Case
  alias Jocker.Engine.Container
  alias Jocker.Engine.Image
  alias Jocker.Engine.MetaData
  alias Jocker.Engine.Volume
  require Jocker.Engine.Config
  import Jocker.Engine.Records

  @moduletag :capture_log

  setup_all do
    Application.stop(:jocker)
    Jocker.Engine.ZFS.clear_zroot()
    Jocker.Engine.Volume.initialize()
    start_supervised({MetaData, [file: Jocker.Engine.Config.metadata_db()]})
    start_supervised(Jocker.Engine.Layer)
    start_supervised({Jocker.Engine.Network, [{"10.13.37.1", "10.13.37.255"}, "jocker0"]})
    start_supervised(Jocker.Engine.ContainerPool)
    start_supervised(Jocker.Engine.APIServer)
    :ok
  end

  setup do
    Process.register(self(), :cli_master)
    MetaData.clear_tables()
    :ok
  end

  test "escript main help" do
    {output, 0} = exec_jocker([])
    assert "\nUsage:\tjocker [OPTIONS] COMMAND" == String.slice(output, 0, 32)
  end

  test "api_server image ls" do
    {:ok, _pid} = Jocker.CLI.EngineClient.start_link([])
    rpc = [MetaData, :list_images, []]
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

    MetaData.add_image(img)

    [msg1, msg2] = jocker_cmd(["image", "ls"])
    assert "NAME           TAG          IMAGE ID       CREATED           \n" == msg1
    assert "test-image     latest       test-image-i   50 years          \n" == msg2
  end

  test "jocker image build" do
    path = "./test/data/test_cli_build_image"

    [msg1] = jocker_cmd(["image", "build", "-t", "lol:test", path])
    id1 = String.slice(msg1, 34, 12)
    assert image(name: "lol", tag: "test") = MetaData.get_image(id1)

    [msg2] = jocker_cmd(["image", "build", path])
    id2 = String.slice(msg2, 34, 12)
    assert image(name: "<none>", tag: "<none>") = MetaData.get_image(id2)
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

    MetaData.add_container(container)
    [msg1] = jocker_cmd(["container", "ls"])

    header =
      "CONTAINER ID   IMAGE                       COMMAND                   CREATED              STATUS    NAME\n"

    assert msg1 == header

    [msg2, msg3] = jocker_cmd(["container", "ls", "-a"])

    assert msg2 == header

    assert msg3 ==
             "testing-id-t   base                        /bin/ls                   50 years             stopped   testname\n"
  end

  test "jocker container create" do
    [id] = jocker_cmd(["container", "create", "base"])
    containers = MetaData.list_containers(all: true)
    assert [container(id: ^id)] = containers

    [id2] = jocker_cmd(["container", "create", "--name", "loltest", "base"])

    containers2 = MetaData.list_containers(all: true)
    assert [container(id: ^id2, name: "loltest") | _] = containers2
  end

  test "jocker container create with volumes" do
    instructions = [
      from: "base",
      run: ["/bin/sh", "-c", "mkdir /testdir1"],
      run: ["/bin/sh", "-c", "mkdir /testdir2"],
      run: ["/bin/sh", "-c", "mkdir /testdir3"],
      run: ["/bin/sh", "-c", "mkdir /testdir4"]
    ]

    {:ok, image(id: image_id, layer_id: layer_id)} = Image.create_image(instructions)

    volume(mountpoint: mountpoint_vol1) = Volume.create_volume("testvol-1")
    volume_testfile1 = Path.join(mountpoint_vol1, "testfile1")
    {"", 0} = System.cmd("/usr/bin/touch", [volume_testfile1])

    volume(mountpoint: mountpoint_vol2) = Volume.create_volume("testvol-2")
    volume_testfile2 = Path.join(mountpoint_vol2, "testfile2")
    {"", 0} = System.cmd("/usr/bin/touch", [volume_testfile2])

    [id] =
      jocker_cmd([
        "container",
        "create",
        "-v",
        "testvol-1:/testdir1:ro",
        "--volume",
        "testvol-2:/testdir2",
        "-v",
        "/testdir3:ro",
        "-v",
        "/testdir4",
        image_id
      ])

    container(layer_id: layer_id) = MetaData.get_container(id)
    layer(mountpoint: mountpoint) = MetaData.get_layer(layer_id)

    assert is_file?(Path.join(mountpoint, "testdir1/testfile1"))

    assert is_file?(Path.join(mountpoint, "testdir2/testfile2"))

    assert {"", 1} ==
             System.cmd("/usr/bin/touch", [Path.join(mountpoint, "testdir3/readonly_test")])

    assert {"", 1} ==
             System.cmd("/usr/bin/touch", [Path.join(mountpoint, "testdir1/readonly_test")])
  end

  test "jocker container start" do
    {:ok, pid} = Container.create(image: "base", cmd: ["/bin/sleep", "10000"])
    container(id: id) = Container.metadata(pid)

    assert [container(id: ^id, running: false)] = MetaData.list_containers(all: true)

    assert ["#{id}\n"] == jocker_cmd(["container", "start", id])
    assert [container(id: ^id, running: true)] = MetaData.list_containers(all: true)
    Container.stop(pid)

    assert [container(id: ^id, running: false)] = MetaData.list_containers(all: true)
  end

  test "jocker container start --attach" do
    {:ok, pid} = Container.create(image: "base", cmd: ["/bin/sh", "-c", "echo lol"])
    container(id: id) = Container.metadata(pid)
    Container.stop(pid)
    assert ["lol\n"] == jocker_cmd(["container", "start", "-a", id])
  end

  test "jocker volume create" do
    volume_name = "testvol"
    assert ["testvol\n"] == jocker_cmd(["volume", "create", "testvol"])
    # Check for idempotency:
    assert ["testvol\n"] == jocker_cmd(["volume", "create", "testvol"])
    volumes = MetaData.list_volumes()
    assert [volume(name: ^volume_name, dataset: dataset, mountpoint: mountpoint)] = volumes
    assert {:ok, %File.Stat{:type => :directory}} = File.stat(mountpoint)
    assert {"#{dataset}\n", 0} == System.cmd("/sbin/zfs", ["list", "-H", "-o", "name", dataset])
  end

  test "jocker volume rm" do
    Jocker.Engine.Volume.create_volume("test1")

    vol2 = Jocker.Engine.Volume.create_volume("test2")

    volume(name: name3) = vol3 = Jocker.Engine.Volume.create_volume()

    assert ["test1\n"] == jocker_cmd(["volume", "rm", "test1"])
    [vol3, vol2] = MetaData.list_volumes()

    assert ["test2\n", "Error: No such volume: test5\n", "#{name3}\n"] ==
             jocker_cmd(["volume", "rm", "test2", "test5", name3])

    assert [] = MetaData.list_volumes()
  end

  test "jocker volume ls" do
    assert ["VOLUME NAME      CREATED           \n"] == jocker_cmd(["volume", "ls"])
    volume(name: name1) = Jocker.Engine.Volume.create_volume("test1")
    volume(name: name2) = Jocker.Engine.Volume.create_volume()
    less_than_a_second = "1 second          "
    one_second = "Less than a second"

    output_scenario1 = [
      "VOLUME NAME      CREATED           \n",
      "#{name2}     #{less_than_a_second}\n",
      "test1            #{less_than_a_second}\n"
    ]

    output_scenario2 = [
      "VOLUME NAME      CREATED           \n",
      "#{name2}     #{one_second}\n",
      "test1            #{one_second}\n"
    ]

    output = jocker_cmd(["volume", "ls"])
    assert output == output_scenario1 or output == output_scenario2
    assert ["#{name2}\n", "test1\n"] == jocker_cmd(["volume", "ls", "--quiet"])
    assert ["#{name2}\n", "test1\n"] == jocker_cmd(["volume", "ls", "-q"])
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

  defp is_file?(filepath) do
    case File.stat(filepath) do
      {:ok, %File.Stat{type: :regular}} -> true
      _notthecase -> false
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
