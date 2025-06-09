defmodule Kleened.API.DeploymentBuild do
  alias OpenApiSpex.{Operation, Cast}
  alias Kleened.API.{Utils, Schemas}
  alias Kleened.Core.{Deployment, ImageBulkBuild}
  require Logger

  import OpenApiSpex.Operation,
    only: [response: 3, request_body: 4]

  def open_api_operation(_) do
    %Operation{
      summary: "image build",
      description: """
      #{Utils.general_websocket_description()}

      * The `data` field in the starting and closing messages is empty in all cases.
      """,
      operationId: "DeploymentBuild",
      requestBody:
        request_body(
          "Image building configuration.",
          "application/json",
          Schemas.DeploymentConfig,
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
  def websocket_handle({:text, deploy_raw}, %{handshaking: true} = state) do
    Logger.debug("receiving build config: #{deploy_raw}")

    with {:json, {:ok, deploy}} <- {:json, Jason.decode(deploy_raw)},
         {:ok, deploy} = Utils.cast_deploy_config(deploy),
         # buildargs = Core.Utils.map2envlist(config.buildargs),
         {:build, :ok} <- {:build, Deployment.build(deploy)} do
      Logger.debug("image build started, awaiting output")
      {[{:text, Utils.starting_message()}], %{handshaking: false}}
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
        Logger.notice("Error bulkbuilding images: #{msg}. Closing websocket.")

        {[
           {:text, Utils.starting_message()},
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
        {:image_bulkbuilder, _pid, {:deployment_build_complete, _images}},
        state
      ) do
    closing = Utils.closing_message("bulkbuild complete")
    {[{:close, 1000, closing}], state}
  end

  def websocket_info(
        {:image_bulkbuilder, _pid, {:image_build_failed, "image build failed"}},
        state
      ) do
    Logger.info("image build failed")
    {[{:text, "image build failed"}], state}
  end

  def websocket_info(
        {:image_bulkbuilder, _pid, {:image_build_failed, {"image build failed", _snapshot}}},
        state
      ) do
    Logger.info("image build failed")
    {[{:text, "image build failed"}], state}
  end

  def websocket_info({:image_bulkbuilder, _pid, {:jail_output, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info({:image_bulkbuilder, _pid, msg}, state) when is_binary(msg) do
    # Status messages from the build process
    {[{:text, msg}], state}
  end

  # message from image_create.ex
  def websocket_info({:image_bulkbuilder, _pid, {:info, msg}}, state) do
    {[{:text, msg}], state}
  end

  def websocket_info({:image_bulkbuilder, _pid, {:image_creator_failed, msg}}, state) do
    Logger.info("image creation failed")
    msg = "Error! #{msg}"
    {[{:text, msg}], state}
  end

  def terminate(reason, _partial_req, _state) do
    Logger.info("Websocket connection closed early: #{inspect(reason)}")
    ImageBulkBuild.stop()
  end
end
