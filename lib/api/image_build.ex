defmodule Kleened.API.ImageBuild do
  alias OpenApiSpex.{Operation, Cast}
  alias Kleened.API.Schemas
  alias Kleened.API.Utils
  alias Kleened.Core
  alias Kleened.Core.Image
  require Logger

  import OpenApiSpex.Operation,
    only: [response: 3, request_body: 4]

  def open_api_operation(_) do
    %Operation{
      summary: "image build",
      description: """
      #{Utils.general_websocket_description()}

      * The `data` field in the starting-message contains the `image_id`.
      * If the build process is successful, the `data` field in the closing-message contains the `image_id` otherwise it contains the latest snapshot or empty string `""` if the build failed before any snapshots have been created.
      """,
      operationId: "ImageBuild",
      requestBody:
        request_body(
          "Image building configuration.",
          "application/json",
          Schemas.ImageBuildConfig,
          required: true
        ),
      responses: %{
        200 => response("no error", "application/json", Schemas.WebSocketMessage)
      }
    }
  end

  # Called on connection initialization
  def init(req0, _state) do
    {:cowboy_websocket, req0, %{handshaking: true}, %{idle_timeout: 60000}}
  end

  # Called on websocket connection initialization.
  def websocket_init(state) do
    {[], state}
  end

  # Ignore messages from the client: No interactive possibility atm.
  def websocket_handle({:text, message_raw}, %{handshaking: true} = state) do
    case Jason.decode(message_raw) do
      {:ok, message} ->
        case Cast.cast(Schemas.ImageBuildConfig.schema(), message) do
          {:ok,
           %Schemas.ImageBuildConfig{
             context: context,
             dockerfile: dockerfile,
             tag: tag,
             buildargs: buildargs,
             cleanup: cleanup,
             quiet: quiet
           }} ->
            buildargs = Core.Utils.map2envlist(buildargs)

            case Image.build(context, dockerfile, tag, buildargs, cleanup, quiet) do
              {:ok, image_id, _pid} ->
                Logger.debug("Building image. Await output.")
                {[{:text, Utils.starting_message(image_id)}], %{handshaking: false}}

              {:error, msg} ->
                Logger.info("Error building image. Closing websocket.")

                {[
                   {:text, Utils.starting_message("")},
                   {:text, msg},
                   {:close, 1011, Utils.error_message("failed to process Dockerfile")}
                 ], state}
            end

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
  def websocket_info(
        {:image_builder, _pid, {:image_build_succesfully, %Schemas.Image{id: id}}},
        state
      ) do
    closing = Utils.closing_message("image created", id)
    {[{:close, 1000, closing}], state}
  end

  def websocket_info({:image_builder, _pid, {:image_build_failed, "image build failed"}}, state) do
    {[{:close, 1011, Utils.error_message("image build failed")}], state}
  end

  def websocket_info(
        {:image_builder, _pid, {:image_build_failed, {"image build failed", image}}},
        state
      ) do
    {[{:close, 1011, Utils.error_message("image build failed", image.id)}], state}
  end

  def websocket_info({:image_builder, _pid, {:jail_output, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info({:image_builder, _pid, msg}, state) when is_binary(msg) do
    # Status messages from the build process
    {[{:text, msg}], state}
  end
end
