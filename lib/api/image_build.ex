defmodule Jocker.API.ImageBuild do
  alias Jocker.Engine.Image
  require Logger

  # Called on connection initialization
  def init(req0, _state) do
    default_values = %{
      # 'tag'-parameter is mandatory
      "context" => "./",
      "dockerfile" => "Dockerfile",
      "quiet" => "false"
    }

    values = Plug.Conn.Query.decode(req0.qs)
    args = Map.merge(default_values, values)

    args =
      case String.downcase(args["quiet"]) do
        "false" ->
          Map.put(args, "quiet", false)

        "true" ->
          Map.put(args, "quiet", true)

        _ ->
          Map.put(args, "quiet", :invalid_arg)
      end

    cond do
      not Map.has_key?(args, "tag") ->
        msg = "missing argument tag"
        req = :cowboy_req.reply(400, %{"content-type" => "text/plain"}, msg, req0)
        {:ok, req, %{}}

      not is_boolean(args["quiet"]) ->
        msg = "invalid value to argument 'quiet'"
        req = :cowboy_req.reply(400, %{"content-type" => "text/plain"}, msg, req0)
        {:ok, req, %{}}

      true ->
        state = %{args: args, request: req0}
        {:cowboy_websocket, req0, state, %{idle_timeout: 60000}}
    end
  end

  # Called on websocket connection initialization.
  def websocket_init(%{args: args} = state) do
    case Image.build(
           args["context"],
           args["dockerfile"],
           args["tag"],
           args["quiet"]
         ) do
      {:ok, _pid} ->
        Logger.debug("Building image. Await output.")
        {[{:text, "OK"}], state}

      {:error, msg} ->
        Logger.info("Error building image. Closing websocket.")
        {[{:text, "ERROR:#{msg}"}, {:close, 1000, "failed to build image"}], state}
    end
  end

  def websocket_handle({:text, _message}, state) do
    # Ignore messages from the client: No interactive possibility atm.
    {:ok, state}
  end

  def websocket_handle({:ping, _}, state) do
    {:ok, state}
  end

  # Format and forward elixir messages to client
  def websocket_info({:image_builder, _pid, {:image_finished, %Image{id: id}}}, state) do
    {[{:close, 1000, "image created with id #{id}"}], state}
  end

  def websocket_info({:image_builder, _pid, {:jail_output, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info({:image_builder, _pid, msg}, state) when is_binary(msg) do
    {[{:text, msg}], state}
  end
end
