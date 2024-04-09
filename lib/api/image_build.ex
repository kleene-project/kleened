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

      * The `data` field in the starting-message contains the image ID of the image being built.
      * If the build process is successful, the `data` field in the closing-message contains the `image_id`.
      * If the build process fails the closing message's `data` field contains the latest snapshot or is set to `""` if the build failed before any snapshots have been created.
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
    {:cowboy_websocket, req0, %{handshaking: true, image_id: nil}, %{idle_timeout: 60000}}
  end

  # Called on websocket connection initialization.
  def websocket_init(state) do
    {[], state}
  end

  # Ignore messages from the client: No interactive possibility atm.
  def websocket_handle({:text, message_raw}, %{handshaking: true} = state) do
    with {:json, {:ok, message}} <- {:json, Jason.decode(message_raw)},
         {:ok, config} <- Cast.cast(Schemas.ImageBuildConfig.schema(), message),
         {:ok, container_config} <-
           Cast.cast(Schemas.ContainerConfig.schema(), config.container_config),
         buildargs = Core.Utils.map2envlist(config.buildargs),
         {:build, {:ok, image_id, _pid}} <-
           {:build,
            Image.build(%Schemas.ImageBuildConfig{
              config
              | container_config: container_config,
                buildargs: buildargs
            })} do
      Logger.debug("Building image. Await output.")
      {[{:text, Utils.starting_message(image_id)}], %{handshaking: false, image_id: image_id}}
    else
      {:error, [openapispex_error | _rest]} ->
        error_message = Cast.Error.message(openapispex_error)
        Logger.notice("Error casting OpenAPI schema. #{inspect(error_message)}. Closing websocke")
        error = Utils.error_message("invalid parameters")
        {[{:text, error_message}, {:close, 1002, error}], state}

      {:json, {:error, json_error}} ->
        Logger.notice("Error parsing json. Closing websocket.")
        error = Utils.error_message("invalid json")
        {[{:text, json_error}, {:close, 1002, error}], state}

      {:build, {:error, msg}} ->
        Logger.notice("Error building image. Closing websocket.")

        {[
           {:text, Utils.starting_message("")},
           {:text, msg},
           {:close, 1011, Utils.error_message("failed to process Dockerfile")}
         ], state}
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
    Logger.info("image build failed")
    {[{:close, 1011, Utils.error_message("image build failed")}], state}
  end

  def websocket_info(
        {:image_builder, _pid, {:image_build_failed, {"image build failed", snapshot}}},
        state
      ) do
    Logger.info("image build failed")
    {[{:close, 1011, Utils.error_message("image build failed", snapshot)}], state}
  end

  def websocket_info({:image_builder, _pid, {:jail_output, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info({:image_builder, _pid, msg}, state) when is_binary(msg) do
    # Status messages from the build process
    {[{:text, msg}], state}
  end

  def terminate(reason, _partial_req, %{image_id: nil}) do
    Logger.info("Websocket connection closed early: #{inspect(reason)}")
  end

  def terminate(:stop, _partial_req, %{image_id: image_id}) do
    Logger.info("Finished building image #{image_id}. Closing connection.")
  end

  def terminate(reason, _partial_req, %{image_id: image_id}) do
    Logger.info("Websocket connection closed while building #{image_id}: #{inspect(reason)}")
    Core.Container.stop(image_id)
    Core.Container.remove(image_id)
    Image.remove(image_id)
    Core.Network.remove("buildnet_" <> image_id)
  end
end
