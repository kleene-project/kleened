defmodule Kleened.Test.WS do
  @moduledoc false

  # Drive kleened's config-first-frame websockets from a test process.
  #
  # The shared TestHelper.receive_frames/2 loop races on abnormal closes (it
  # drops every collected frame when gun reports the close before the caller
  # drained it), which showed up when several test files run in one BEAM —
  # collecting straight from the socket is deterministic. Both the image
  # import and the image pull tests use this.

  import ExUnit.Assertions

  @kleened_host "/var/run/kleened.sock"

  @doc """
  Open the websocket at `endpoint`, send `config` (encoded as JSON) as the
  first frame, and collect until the closing/error result arrives.

  Returns `{:ok, data}` for a normal close (data = the closing payload) or
  `{:error, message}` when the daemon reported an error.
  """
  @spec send_config_and_collect(String.t(), map(), pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def send_config_and_collect(endpoint, config, timeout \\ 30_000) do
    {:ok, conn} = :gun.open_unix(@kleened_host, %{protocols: [:http]})
    {:ok, _} = :gun.await_up(conn)
    :gun.ws_upgrade(conn, endpoint)

    stream =
      receive do
        {:gun_upgrade, ^conn, ref, ["websocket"], _} -> ref
      after
        5_000 -> flunk("websocket upgrade timed out")
      end

    :gun.ws_send(conn, stream, {:text, Jason.encode!(config)})
    collect(conn, stream, timeout)
  end

  defp collect(conn, stream, timeout) do
    receive do
      {:gun_ws, ^conn, ^stream, {:text, msg}} ->
        case Jason.decode(msg) do
          # progress frames are plain text, not JSON
          {:error, _} -> collect(conn, stream, timeout)
          {:ok, decoded} -> result(decoded) || collect(conn, stream, timeout)
        end

      {:gun_ws, ^conn, ^stream, {:close, _code, msg}} ->
        {:ok, decoded} = Jason.decode(msg)
        result(decoded)

      # The close frame may already be in the mailbox; give it a chance
      # before giving up.
      {:gun_down, ^conn, :ws, _reason, _} ->
        receive do
          {:gun_ws, ^conn, ^stream, {:close, _code, msg}} ->
            {:ok, decoded} = Jason.decode(msg)
            result(decoded)
        after
          500 -> flunk("websocket closed before result frame")
        end
    after
      timeout -> flunk("timed out waiting for websocket result")
    end
  end

  defp result(%{"msg_type" => "error", "message" => message}), do: {:error, message}
  defp result(%{"msg_type" => "closing", "data" => data}), do: {:ok, data}
  # any other frame is progress: keep collecting
  defp result(_progress_frame), do: nil
end
