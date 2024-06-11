defmodule DeploymentTest do
  require Logger
  use Kleened.Test.ConnCase
  alias ExUnit.CaptureLog

  @moduletag :capture_log

  setup %{host_state: state} do
    TestHelper.cleanup()

    on_exit(fn ->
      CaptureLog.capture_log(fn ->
        Logger.info("Cleaning up after test...")
        TestHelper.cleanup()
        TestHelper.compare_to_baseline_environment(state)
      end)
    end)

    :ok
  end

  test "testing schema" do
    {:ok, config} =
      YamlElixir.read_from_string("""
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

    case TestHelper.deployment_diff(config) do
      {:ok, json_output} ->
        Logger.warning("Deployment testing SUCCES: #{json_output}")

      {:error, message} ->
        Logger.warning("Deployment testing FAILURE: #{message}")
    end
  end
end
