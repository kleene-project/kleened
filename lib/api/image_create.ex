defmodule Kleened.API.ImageCreate do
  alias Kleened.Core
  alias Kleened.API.Schemas
  alias Kleened.API.Utils
  alias OpenApiSpex.{Operation, Cast}

  import OpenApiSpex.Operation,
    only: [response: 3, request_body: 4]

  require Logger

  def open_api_operation(_) do
    %Operation{
      summary: "image create",
      description: "make a description of the websocket endpoint here.",
      operationId: "ImageCreate",
      requestBody:
        request_body(
          "Image building configuration.",
          "application/json",
          Schemas.ImageCreateConfig,
          required: true
        ),
      responses: %{
        200 => response("no error", "application/json", Schemas.IdMessage)
      }
    }
  end

  # Called on connection initialization
  def init(req0, _state) do
    {:cowboy_websocket, req0, %{handshaking: true}, %{idle_timeout: 60000}}
  end

  def websocket_init(state) do
    {[], state}
  end

  def websocket_handle({:text, message_raw}, %{handshaking: true} = state) do
    case Jason.decode(message_raw) do
      {:ok, message} ->
        case Cast.cast(Schemas.ImageCreateConfig.schema(), message) do
          {:ok, config} ->
            Core.ImageCreate.start_image_creation(config)
            Logger.debug("Creating image with config #{inspect(config)}. Await output.")
            {[{:text, Utils.starting_message()}], %{handshaking: false}}

          {:error, [openapispex_error | _rest]} ->
            error_message = Cast.Error.message(openapispex_error)
            error = Utils.error_message("invalid parameters")
            {[{:text, error_message}, {:close, 1002, error}], state}
        end

      {:error, json_error} ->
        error = Utils.error_message("invalid json")
        {[{:text, json_error}, {:close, 1002, error}], state}
    end
  end

  def websocket_handle({:text, _message}, %{handshaking: false} = state) do
    {:ok, state}
  end

  def websocket_handle({:ping, _}, state) do
    {:ok, state}
  end

  # Format and forward elixir messages to client
  def websocket_info({:image_creator, _pid, {:ok, %Schemas.Image{id: id}}}, state) do
    closing = Utils.closing_message("image created", id)
    {[{:close, 1000, closing}], state}
  end

  def websocket_info({:image_creator, _pid, {:error, reason}}, state) do
    error = Utils.error_message("image creation failed")
    {[{:text, reason}, {:close, 1011, error}], state}
  end

  def websocket_info({:image_creator, _pid, {:info, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info({:EXIT, _pid, _reason}, state) do
    error = Utils.error_message("image creation failed")
    {[{:close, 1011, error}], state}
  end

  def websocket_info(unknown_msg, state) do
    Logger.warn("unknown message received:received:  #{inspect(unknown_msg)}")
    {:ok, state}
  end
end
