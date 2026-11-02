defmodule Kleened.API.ImagePull do
  alias Kleened.Core
  alias Kleened.API.Schemas
  alias Kleened.API.Utils
  alias OpenApiSpex.{Operation, Cast}

  import OpenApiSpex.Operation,
    only: [response: 3, request_body: 4]

  require Logger

  def open_api_operation(_) do
    %Operation{
      summary: "image pull",
      description: """
      #{Utils.general_websocket_description()}

      * The starting-message does not have any content.
      * If the image pull finishes succesfully, the ID of the newly pulled image is stored in the
      `data` field of the closing-message.
      """,
      operationId: "ImagePull",
      requestBody:
        request_body(
          "Image pull configuration.",
          "application/json",
          Schemas.ImagePullConfig,
          required: true
        ),
      responses: %{
        200 => response("no error", "application/json", Schemas.WebSocketMessage),
        400 => response("no error", "application/json", Schemas.WebSocketMessage)
      }
    }
  end

  # Called on connection initialization
  def init(req0, _state) do
    {:cowboy_websocket, req0, %{handshaking: true}, %{idle_timeout: 600_000}}
  end

  def websocket_init(state) do
    {[], state}
  end

  def websocket_handle({:text, message_raw}, %{handshaking: true} = state) do
    case Jason.decode(message_raw) do
      {:ok, message} ->
        case Cast.cast(Schemas.ImagePullConfig.schema(), message) do
          {:ok, config} ->
            Core.ImageCreate.pull_oci(config)
            Logger.debug("Pulling OCI image with config #{inspect(config)}. Await output.")
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
    Logger.info("image pulled with id #{id}")
    closing = Utils.closing_message("image pulled", id)
    {[{:close, 1000, closing}], state}
  end

  def websocket_info({:image_creator, _pid, {:error, reason}}, state) do
    # Close-frame payloads are capped at 125 bytes by the websocket spec, and
    # the JSON envelope adds ~55 — truncate the reason hard. The full reason
    # has already been relayed as a text frame.
    error = Utils.error_message("image pull failed: #{truncate(reason, 40)}")
    {[{:text, reason}, {:close, 1011, error}], state}
  end

  def websocket_info({:image_creator, _pid, {:info, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info({:EXIT, _pid, reason}, state) do
    error = Utils.error_message("image pull crashed: #{inspect(reason)}")
    {[{:close, 1011, error}], state}
  end

  def websocket_info(unknown_msg, state) do
    Logger.warning("unknown message received: #{inspect(unknown_msg)}")
    {:ok, state}
  end

  defp truncate(reason, max_length) do
    if String.length(reason) > max_length do
      String.slice(reason, 0, max_length) <> "..."
    else
      reason
    end
  end
end
