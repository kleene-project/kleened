defmodule DeploymentTest do
  require Logger
  use Kleened.Test.ConnCase
  alias ExUnit.CaptureLog
  alias Kleened.API.Schemas

  @moduletag :capture_log

  setup %{host_state: state} do
    TestHelper.cleanup()

    on_exit(fn ->
      CaptureLog.capture_log(fn ->
        Logger.info("Cleaning up after test...")
        TestHelper.cleanup()
        Kleened.Test.Utils.compare_to_baseline_environment(state)
      end)
    end)

    :ok
  end

  test "deployment diff of a spec whose objects all exist" do
    config =
      YamlElixir.read_from_string!("""
      ---
      containers:
        - name: "postgres1"
          image: "FreeBSD:latest"

      images:
        - tag: "FreeBSD:latest"
          method: "zfs-clone"
          zfs_dataset: "zroot/kleene_basejail"

      networks:
        - name: "testnet"
          type: "bridge"
          subnet: "10.13.37.0/24"

      volumes:
        - name: "database-storage"
      """)

    [_, _, _, closing_message] =
      TestHelper.image_create(%{
        tag: "FreeBSD:latest",
        method: "zfs-clone",
        zfs_dataset: "zroot/kleene_basejail"
      })

    assert {1000,
            %Schemas.WebSocketMessage{
              msg_type: "closing",
              message: "image created"
            }} = closing_message

    assert {:ok, _json} = TestHelper.deployment_diff(config)
  end
end
