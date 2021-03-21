defmodule Jocker.CLI.Utils do
  alias Jocker.CLI.EngineClient
  require Logger

  def rpc(cmd) do
    case Process.whereis(EngineClient) do
      nil ->
        case EngineClient.start_link([]) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            Logger.error("jocker-cli: Error connecting to backend: #{reason}")
        end

      _pid ->
        :ok
    end

    :ok = EngineClient.command(cmd)
    fetch_reply()
  end

  def to_cli(msg \\ nil, eof \\ nil) do
    case msg do
      nil -> :ok
      msg -> Process.send(:cli_master, {:msg, msg}, [])
    end

    case eof do
      :eof -> Process.send(:cli_master, {:msg, :eof}, [])
      nil -> :ok
    end
  end

  def fetch_reply() do
    receive do
      {:server_reply, reply} ->
        reply

      :tcp_closed ->
        :tcp_closed

      what ->
        {:error, "ERROR: Unexpected message received from backend: #{inspect(what)}"}
    end
  end

  def format_timestamp(ts) do
    case ts do
      "CREATED" -> cell("CREATED", 18)
      _ -> cell(Jocker.Engine.Utils.human_duration(ts), 18)
    end
  end

  def cell(content, size) do
    content_length = String.length(content)

    case content_length < size do
      true -> content <> sp(size - content_length)
      false -> String.slice(content, 0, size)
    end
  end

  def sp(n) do
    String.pad_trailing(" ", n)
  end
end
