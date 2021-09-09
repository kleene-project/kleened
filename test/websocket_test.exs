defmodule WebSocketTest do
  use ExUnit.Case
  require Logger

  alias Jocker.Engine.{Container, Image}
  alias :gun, as: Gun

  @moduletag :capture_log

  test "simple websocket test" do
    {ok, conn} = Gun.open(:binary.bin_to_list("localhost"), 8085)

    receive do
      {:gun_up, ^conn, :http} -> :ok
      _ -> Logger.info("connection up!")
    end

    :gun.ws_upgrade(conn, :binary.bin_to_list("/containers/lolmand/attach"))

    stream =
      receive do
        {:gun_upgrade, ^conn, stream_ref, ["websocket"], _headers} ->
          Logger.info("websocket initialized")
          stream_ref

        {:gun_response, ^conn, _, _, status, headers} ->
          exit({:ws_upgrade_failed, status, headers})

        {:gun_error, ^conn, _stream_ref, reason} ->
          exit({:ws_upgrade_failed, reason})

        ## More clauses here as needed.

        msg ->
          exit({:ws_upgrade_failed, "unknown message #{inspect(msg)} received."})
      end

    Gun.ws_send(conn, {:text, "ping"})

    receive do
      {:gun_ws, ^conn, stream, {:text, "pong"}} -> Logger.warn("lol")
      what -> Logger.info("success!")
    end

    assert false
  end
end
