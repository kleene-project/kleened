defmodule CLITest do
  use ExUnit.Case
  import Jocker.Engine.Records

  setup_all do
    Jocker.Engine.ZFS.clear_zroot()
    start_supervised(Jocker.Engine.MetaData)
    start_supervised(Jocker.Engine.Layer)
    start_supervised({Jocker.Engine.Network, [{"10.13.37.1", "10.13.37.255"}, "jocker0"]})
    start_supervised(Jocker.Engine.ContainerPool)
    start_supervised(Jocker.Engine.APIServer)
    :ok
  end

  setup do
    Process.register(self(), :cli_master)
    Jocker.Engine.MetaData.clear_tables()
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

    stop_client()
  end

  test "jocker with no arguments" do
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
    assert "NAME           TAG          IMAGE ID       CREATED         \n" == msg1
    assert "test-image     latest       test-image-i   1970-01-01T00:00\n" == msg2
  end

  test "jocker image build" do
    path = "./test/data/test_cli_build_image"

    {:ok, _pid} = Jocker.CLI.EngineClient.start_link([])
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
        command: "/bin/ls",
        image_id: "base",
        created: DateTime.to_iso8601(DateTime.from_unix!(1))
      )

    Jocker.Engine.MetaData.add_container(container)
    [msg1] = jocker_cmd(["container", "ls"])
    stop_client()

    header =
      "CONTAINER ID   IMAGE                       COMMAND                   CREATED            STATUS    NAME\n"

    assert msg1 == header

    [msg2, msg3] = jocker_cmd(["container", "ls", "-a"])

    assert msg2 == header

    assert msg3 ==
             "testing-id-t   base                        /bin/ls                   1970-01-01T00:00   stopped   testname\n"
  end

  defp stop_client() do
    GenServer.stop(Jocker.CLI.EngineClient)
  end

  defp jocker_cmd(command) do
    Jocker.CLI.Main.main_(command)
    collect_output([])
  end

  defp collect_output(output) do
    receive do
      {:msg, :eof} ->
        Enum.reverse(output)

      {:msg, msg} ->
        collect_output([msg | output])

      other ->
        IO.puts("Unexpected message received while waiting for cli-messages: #{other}")
        exit(:shutdown)
    end
  end

  defp exec_jocker(args) do
    {:ok, path} = File.cwd()
    System.cmd("#{path}/jocker", args)
  end
end
