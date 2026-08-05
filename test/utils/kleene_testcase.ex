defmodule Kleened.Test.ConnCase do
  @moduledoc """
  Shared case template for the tests that need a running daemon.

  Every test starts from a clean host and leaves one behind: `cleanup/0` removes
  all containers, volumes, networks and images (except the `FreeBSD:testing`
  base image) before the test runs and again when it exits.

  After the trailing cleanup, the host is compared against the snapshot taken
  before the test. What that catches is the residue cleanup *cannot* remove -- a
  leaked jail, an interface that was never destroyed, a devfs mount left behind
  -- so the test that caused the leak is the one that fails, rather than some
  unrelated test later in the run.

  `network_test.exs` and `exec_test.exs` used to skip the baseline check because
  their hand-written setup blocks never had it; they pass with it enabled.
  """
  use ExUnit.CaseTemplate

  require Logger

  using do
    quote do
      use Plug.Test
      import Plug.Conn
      import OpenApiSpex.TestAssertions
      import OpenApiSpex.Schema, only: [example: 1]
    end
  end

  setup _tags do
    # Added to the context to validate responses with assert_schema/3
    api_spec = Kleened.API.Spec.spec()

    state = Kleened.Test.Utils.get_host_state()
    Kleened.Test.Utils.cleanup()

    on_exit(fn ->
      ExUnit.CaptureLog.capture_log(fn ->
        Logger.info("Cleaning up after test...")
        Kleened.Test.Utils.cleanup()
        Kleened.Test.Utils.compare_to_baseline_environment(state)
      end)
    end)

    {:ok, api_spec: api_spec, host_state: state}
  end
end
