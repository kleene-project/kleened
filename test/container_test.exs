defmodule ContainerTest do
  use Kleened.Test.ConnCase
  alias Kleened.Core.{Container, Exec, MetaData, OS}
  alias Kleened.API.Schemas

  @moduletag :capture_log

  test "containers with '--restart on-startup' will be started when kleened starts" do
    TestHelper.network_create(%{
      name: "testnet",
      subnet: "172.19.0.0/16",
      gateway: "<auto>",
      type: "bridge"
    })

    config =
      container_config(%{
        name: "test-restart1",
        jail_param: ["mount.nodevfs"],
        cmd: ["/bin/sleep", "10"],
        network_driver: "ipnet",
        network: "testnet",
        restart_policy: "on-startup"
      })

    %Schemas.Container{id: container_id1} =
      container_succesfully_create(
        Map.merge(config, %{name: "test-restart1", network_driver: "ipnet"})
      )

    %Schemas.Container{id: container_id2} =
      container_succesfully_create(
        Map.merge(config, %{name: "test-restart2", network_driver: "vnet"})
      )

    Application.stop(:kleened)
    assert {"", 0} == OS.shell("ifconfig kleene0 destroy")

    Application.start(:kleened)

    :timer.sleep(200)

    # Fails because running is not used!
    %{container: %{running: true}} = TestHelper.container_inspect(container_id1)
    %{container: %{running: true}} = TestHelper.container_inspect(container_id2)

    assert {_, 0} = OS.shell("ifconfig kleene0")

    cmd = ["/bin/sh", "-c", "host -W 1 freebsd.org 1.1.1.1"]

    {:ok, exec_id} = Exec.create(%Schemas.ExecConfig{container_id: container_id1, cmd: cmd})

    {_closing_msg, [process_output]} =
      TestHelper.exec_valid_start(%Schemas.ExecStartConfig{
        exec_id: exec_id,
        attach: true,
        start_container: false
      })

    # Assert the shape of the answer rather than freebsd.org's current A record,
    # which changes independently of Kleene.
    assert process_output =~ ~r/freebsd\.org has address \d{1,3}(\.\d{1,3}){3}/

    {:ok, exec_id} = Exec.create(%Schemas.ExecConfig{container_id: container_id2, cmd: cmd})

    {_closing_msg, [process_output]} =
      TestHelper.exec_valid_start(%Schemas.ExecStartConfig{
        exec_id: exec_id,
        attach: true,
        start_container: false
      })

    # Assert the shape of the answer rather than freebsd.org's current A record,
    # which changes independently of Kleene.
    assert process_output =~ ~r/freebsd\.org has address \d{1,3}(\.\d{1,3}){3}/

    Container.stop(container_id1)
    Container.stop(container_id2)
  end

  test "creating a container with a name that is already taken fails with 409" do
    container_succesfully_create(container_config(%{name: "dup-name-test"}))

    response =
      conn(:post, "/containers/create", container_config(%{name: "dup-name-test"}))
      |> put_req_header("content-type", "application/json")
      |> Kleened.API.Router.call(Kleened.API.Router.init([]))

    assert response.status == 409

    assert %{message: "container name is already taken"} ==
             Jason.decode!(response.resp_body, keys: :atoms)
  end

  test "a name that is a prefix of another container's id does not collide with it" do
    %{id: container_id} = container_succesfully_create(container_config(%{name: "prefix-source"}))

    # A short name (here: the first chars of the other container's id) must be
    # treated as a *name*, not as an id-prefix: no 409, no match on the id.
    response =
      conn(
        :post,
        "/containers/create",
        container_config(%{name: String.slice(container_id, 0, 2)})
      )
      |> put_req_header("content-type", "application/json")
      |> Kleened.API.Router.call(Kleened.API.Router.init([]))

    assert response.status == 201
    other_id = Jason.decode!(response.resp_body, keys: :atoms).id
    assert other_id != container_id

    assert String.slice(container_id, 0, 2) ==
             Jason.decode!(Jason.encode!(MetaData.get_container(other_id)), keys: :atoms)[:name]
  end

  defp container_config(config) do
    defaults = %{
      name: "container_testing",
      image: "FreeBSD:testing",
      user: "root",
      attach: true
    }

    Map.merge(defaults, config)
  end

  defp container_succesfully_create(config) do
    %{id: container_id} = TestHelper.container_create(config)
    MetaData.get_container(container_id)
  end
end
