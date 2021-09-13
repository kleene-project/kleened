defmodule Jocker.Engine.HTTPImageBuild do
  alias Jocker.Engine.Image
  require Logger

  # Called on connection initialization
  def init(req, _state) do
    state = %{request: req}
    {:cowboy_websocket, req, state, %{idle_timeout: 60000}}
  end

  # Called on websocket connection initialization.
  def websocket_init(state) do
    default_values = %{
      # 'tag'-parameter is mandatory
      "context" => "./",
      "dockerfile" => "Dockerfile",
      "quiet" => "false"
    }

    values = Plug.Conn.Query.decode(state.request.qs)
    args = Map.merge(default_values, values)

    args =
      case args["quiet"] do
        "false" ->
          Map.put(args, "quiet", false)

        "true" ->
          Map.put(args, "quiet", true)

        _ ->
          Map.put(args, "quiet", :invalid_arg)
      end

    cond do
      not Map.has_key?(args, "tag") ->
        {[{:close, 1000, "error:missing argument tag"}], state}

      not is_boolean(args["quiet"]) ->
        {[{:close, 1000, "error:invalid value to argument 'quiet'"}], state}

      true ->
        {:ok, _pid} =
          Image.build(
            args["context"],
            args["dockerfile"],
            args["tag"],
            args["quiet"]
          )

        {[{:text, "ok:"}], state}
    end
  end

  def websocket_handle({:text, "ping"}, state) do
    # ping messages should be handled by cowboy
    {:ok, state}
  end

  def websocket_handle({:text, _message}, state) do
    # Ignore messages from the client (i.e. no interactive possibility atm.
    {:ok, state}
  end

  # Format and forward elixir messages to client
  def websocket_info({:image_builder, _pid, {:image_finished, %Image{id: id}}}, state) do
    {[{:close, 1000, "exit:image created with id #{id}"}], state}
  end

  def websocket_info({:image_builder, _pid, {:jail_output, msg}}, state) do
    {[{:text, "io:" <> msg}], state}
  end

  def websocket_info({:image_builder, _pid, msg}, state) when is_binary(msg) do
    {[{:text, "io:" <> msg}], state}
  end

  def websocket_info({:image_builder, _pid, msg}, state) do
    Logger.warn("unknown message received from image-builder: #{inspect(msg)}")
    {:ok, state}
  end

  def websocket_info(message, state) do
    Logger.warn("unknown message received: #{inspect(message)}")
    {:ok, state}
  end

  # No matter why we terminate, remove all of this pids subscriptions
  def websocket_terminate(_reason, _state) do
    :ok
  end
end
