defmodule Kleened.API.Utils do
  alias OpenApiSpex.{Cast, Reference}
  alias Kleened.API.Schemas
  alias Kleened.API.Schemas.WebSocketMessage, as: Message
  require Logger
  # Remember that control-frames, such as Close frames must not exceed 125 bytes

  def error_response(msg) do
    Jason.encode!(%{message: msg})
  end

  def id_response(id) do
    Jason.encode!(%{id: id})
  end

  def idlist_response(ids) do
    Jason.encode!(ids)
  end

  def closing_message(msg, data \\ "") do
    Jason.encode!(%Message{
      msg_type: "closing",
      message: msg,
      data: data
    })
  end

  def starting_message(data \\ "") do
    Jason.encode!(%Message{
      msg_type: "starting",
      message: "",
      data: data
    })
  end

  def error_message(msg, data \\ "") do
    Jason.encode!(%Message{
      msg_type: "error",
      message: msg,
      data: data
    })
  end

  def general_websocket_description() do
    """
    > **Important**: This is a 'dummy' specification since the actual endpoint is websocket-based.
    > Below is a description of the websocket protocol and how it relates to the dummy spec.

    ## General websocket protocol used by Kleened
    All of Kleened's websocket endpoints follows a similar pattern, having only differences
    in the contents of the fields in the protocol frames.
    The specifics of the particular endpoint is described below the generic description of the
    protocol.

    Once the websocket is established Kleened expects a configuration-frame which is given by
    the specified request body schema. The contents of the request body should be sent as an
    initial websocket frame instead of being contained in the initiating request.

    When the config is received, Kleened sends a 'starting-message' back to the client, indicating
    that Kleened has begun processing the request.
    The starting message, like all protocol messages, follows the schema shown for
    the 200-response below (the WebSocketMessage schema) and has `msg_type` set to `starting`.
    After the starting-message, subsequent frames will be 'raw' output from the running process.
    When the process is finished, Kleened closes the websocket with a Close Code 1000 and a
    WebSocketMessage contained in the Close frame's Close Reason.
    The `msg_type` is set to `closing` but the contents of the `data` and `message` fields
    depend on the particular endpoint.

    If the initial configuration message schema is invalid, kleened closes the websocket with
    Close Code 1002 and a WebSocketMessage as the Close frame's Close Reason.
    The `msg_type` is set to `error` and the contents of the `data` and `message` fields will
    depend on the specific error.
    This only happens before a starting-message have been sent to the client.

    If Kleened encounters an error during process execution, Kleened closes the websocket with
    Close Code 1011 and a WebSocketMessage as the Close frame's reason. The `msg_type` is set to
    `error` and the contents of the `data` and `message` fields will depend on the specific error.

    If any unexpected errors/crashes occur during the lifetime of the websocket, Kleend closes
    the websocket with Close Code 1011 and an empty reason field.

    ## Endpoint-specific details
    The following specifics pertain to this endpoint:
    """
  end

  @spec cast_deploy_config(%{}) :: {:ok, %Schemas.DeploymentConfig{}} | {:error, term()}
  def cast_deploy_config(deploy) do
    Logger.debug("Casting deploy-config: #{inspect(deploy)}")

    with {:ok, deploy} <-
           OpenApiSpex.cast_value(
             deploy,
             Schemas.DeploymentConfig.schema(),
             Kleened.API.Spec.spec()
           ),
         Cast.cast(%Reference{"$ref": "#/components/schemas/DeploymentConfig"}, deploy),
         {:ok, deploy_images} <- cast_deploy_images(deploy.images),
         {:ok, deploy_containers} <- cast_deploy_containers(deploy.containers) do
      {:ok,
       %Schemas.DeploymentConfig{deploy | images: deploy_images, containers: deploy_containers}}
    else
      {:error, msg} ->
        {:error, msg}
    end
  end

  def cast_image_build_config(config) do
    with {:ok, config} <- Cast.cast(Schemas.ImageBuildConfig.schema(), config),
         {:ok, container_config} <-
           Cast.cast(Schemas.ContainerConfig.schema(), config.container_config),
         {:ok, networks} <- cast_endpoints(config.networks),
         {:ok, mounts} <- cast_mountpoints(container_config.mounts) do
      config = %Schemas.ImageBuildConfig{
        config
        | container_config: %Schemas.ContainerConfig{container_config | mounts: mounts},
          networks: networks
      }

      {:ok, config}
    else
      {:error, msg} ->
        {:error, msg}
    end
  end

  @spec cast_deploy_containers([%{}]) ::
          {:ok, [%Schemas.ContainerConfig{}]} | {:error, term()}
  def cast_deploy_containers(container_configs) do
    Logger.debug("Casting deploy containers: #{inspect(container_configs)}")

    cast_deploy_containers(container_configs, [])
  end

  def cast_deploy_containers([], containers) do
    {:ok, containers}
  end

  def cast_deploy_containers([config | rest], containers) do
    case Cast.cast(Schemas.ContainerConfig.schema(), config) do
      {:ok, container_config} -> cast_deploy_containers(rest, [container_config | containers])
      {{:error, msg}, _} -> {:error, msg}
    end
  end

  @spec cast_deploy_images([%{}]) ::
          {:ok, [%Schemas.ImageBuildConfig{} | %Schemas.ImageCreateConfig{}]} | {:error, term()}
  def cast_deploy_images(images) do
    Logger.debug("Casting deploy images: #{inspect(images)}")
    cast_deploy_images(images, [])
  end

  defp cast_deploy_images([], casted) do
    {:ok, casted}
  end

  defp cast_deploy_images([image_config_raw | rest], casted) do
    cast_build = Cast.cast(Schemas.ImageBuildConfig.schema(), image_config_raw)
    cast_create = Cast.cast(Schemas.ImageCreateConfig.schema(), image_config_raw)

    case {cast_build, cast_create} do
      {{:ok, build_config}, _} -> cast_deploy_images(rest, [build_config | casted])
      {_, {:ok, create_config}} -> cast_deploy_images(rest, [create_config | casted])
      # If both faild to be casted, use the errors from the ImageBuildConfig config
      {{:error, msg}, _} -> {:error, msg}
    end
  end

  @spec cast_endpoints([%{}]) :: {:ok, [%Schemas.EndPointConfig{}]} | {:error, term()}
  def cast_endpoints(endpoints) do
    cast_endpoints(endpoints, [])
  end

  defp cast_endpoints([endpoint_raw | rest], endpoints) do
    case Cast.cast(Schemas.EndPointConfig.schema(), endpoint_raw) do
      {:ok, endpoint} -> cast_endpoints(rest, [endpoint | endpoints])
      {:error, msg} -> {:error, msg}
    end
  end

  defp cast_endpoints([], endpoints) do
    {:ok, endpoints}
  end

  @spec cast_mountpoints([%{}]) :: {:ok, [%Schemas.MountPointConfig{}]} | {:error, term()}
  def cast_mountpoints(mountpoints) do
    cast_mountpoints(mountpoints, [])
  end

  defp cast_mountpoints([mountpoint_raw | rest], mountpoints) do
    case Cast.cast(Schemas.MountPointConfig.schema(), mountpoint_raw) do
      {:ok, mountpoint} -> cast_mountpoints(rest, [mountpoint | mountpoints])
      {:error, msg} -> {:error, msg}
    end
  end

  defp cast_mountpoints([], mountpoints) do
    {:ok, mountpoints}
  end
end
