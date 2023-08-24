defmodule Kleened.API.ImageCreate do
  alias Kleened.Core
  alias Kleened.API.Schemas
  require Logger

  # Called on connection initialization
  def init(req0, _state) do
    case validate_request(req0) do
      {:ok, state} ->
        {:cowboy_websocket, req0, state, %{idle_timeout: 60000}}

      {:error, msg} ->
        req = :cowboy_req.reply(400, %{"content-type" => "text/plain"}, msg, req0)
        {:ok, req, %{}}
    end
  end

  def websocket_init(%{args: args} = state) do
    Core.ImageCreate.start_image_creation(args)
    Logger.debug("Creating image with config #{inspect(args)}. Await output.")
    {:ok, state}
  end

  def websocket_handle({:text, _message}, state) do
    {:ok, state}
  end

  def websocket_handle({:ping, _}, state) do
    {:ok, state}
  end

  # Format and forward elixir messages to client
  def websocket_info({:image_creator, _pid, {:ok, %Schemas.Image{} = image}}, state) do
    {[{:close, 1000, "ok:#{image.id}"}], state}
  end

  def websocket_info({:image_creator, _pid, {:error, reason}}, state) do
    {[{:close, 1000, "image creation failed: #{reason}"}], state}
  end

  def websocket_info({:image_creator, _pid, {:info, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info({:EXIT, _pid, _reason}, state) do
    {[{:close, 1000, "image creation failed"}], state}
  end

  def websocket_info(unknown_msg, state) do
    Logger.warn("unknown message received:received:  #{inspect(unknown_msg)}")
    {:ok, state}
  end

  defp validate_request(req0) do
    default_values = %{
      "method" => "fetch",
      "tag" => "",
      "force" => "false",
      "zfs_dataset" => ""
    }

    values = Plug.Conn.Query.decode(req0.qs)
    args = Map.merge(default_values, values)
    {:ok, args} = OpenApiSpex.Cast.cast(Schemas.ImageCreateConfig.schema(), args)
    state = %{args: args, request: req0}
    {:ok, state}
  end
end
