defmodule Jocker.CLI.Utils do
  alias Jocker.CLI.EngineClient
  require Logger

  def rpc(cmd, method \\ :sync) do
    case EngineClient.start_link([]) do
      {:ok, pid} ->
        :ok = EngineClient.command(pid, cmd)

        case method do
          :sync -> fetch_single_reply(pid)
          :async -> fetch_reply()
        end

      {:error, reason} ->
        Logger.error("jocker-cli: Error connecting to backend: #{reason}")
    end
  end

  def fetch_single_reply(pid) do
    reply = fetch_reply()
    :tcp_closed = fetch_reply()
    :ok = GenServer.stop(pid)
    reply
  end

  def fetch_reply() do
    receive do
      {:server_reply, {:tcp_error, reason}} ->
        to_cli("\nError: connection to Jocker engine closed unexpectedly\n", :eof)
        :error

      {:server_reply, reply} ->
        reply

      what ->
        to_cli("Error: unexpected message received from backend: #{inspect(what)}", :eof)
        :error
    after
      60_000 ->
        to_cli("Error: connection to jockerd timed out.", :eof)
        {:error, :timeout}
    end
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
