defmodule Jocker.API.Container do
  alias OpenApiSpex.{Operation, Schema}
  alias Jocker.Engine.Container
  alias Jocker.API.Schemas
  require Logger

  import OpenApiSpex.Operation,
    only: [parameter: 4, parameter: 5, request_body: 4, response: 3, response: 4]

  defmodule List do
    use Plug.Builder

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.List"
    )

    plug(:list)

    def open_api_operation(_) do
      %Operation{
        # tags: ["users"],
        summary: "List containers",
        description: "Returns a compact listing of containers.",
        operationId: "Container.List",
        parameters: [
          parameter(
            :all,
            :query,
            %Schema{type: :boolean},
            "Return all containers. By default, only running containers are shown."
          )
        ],
        responses: %{
          200 =>
            response("no error", "application/json", %Schema{
              type: :array,
              items: Schemas.ContainerSummary
            })
        }
      }
    end

    def list(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)

      opts =
        case conn.query_params do
          %{"all" => "true"} -> [all: true]
          _ -> [all: false]
        end

      container_list = Container.list(opts) |> Jason.encode!()

      conn
      |> Plug.Conn.put_resp_header("Content-Type", "application/json")
      |> Plug.Conn.send_resp(200, container_list)
    end
  end

  defmodule Create do
    use Plug.Builder
    alias Jocker.API.Utils

    plug(Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason
    )

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.Create"
    )

    plug(:create)

    def open_api_operation(_) do
      %Operation{
        summary: "Create a container",
        operationId: "Container.Create",
        parameters: [
          parameter(
            :name,
            :query,
            %Schema{type: :string},
            "Assign the specified name to the container. Must match `/?[a-zA-Z0-9][a-zA-Z0-9_.-]+`.",
            required: true
          )
        ],
        requestBody:
          request_body(
            "Container configuration to use when creating the container",
            "application/json",
            Schemas.ContainerConfig,
            required: true
          ),
        responses: %{
          201 => response("no error", "application/json", Schemas.IdResponse),
          404 => response("no such image", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def create(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      conn = Plug.Conn.put_resp_header(conn, "Content-Type", "application/json")

      name = conn.query_params["name"]
      container_config = conn.body_params

      case Container.create(name, container_config) do
        {:ok, %Container{id: id}} ->
          send_resp(conn, 201, Utils.id_response(id))

        {:error, :image_not_found} ->
          send_resp(conn, 404, Utils.error_response("no such image '#{container_config.image}'"))

        unknown_msg ->
          Logger.warn("unknown error creating container: #{inspect(unknown_msg)}")
          send_resp(conn, 500, Utils.error_response("server error"))
      end
    end
  end

  defmodule Remove do
    use Plug.Builder
    alias Jocker.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.Delete"
    )

    plug(:remove)

    def open_api_operation(_) do
      %Operation{
        summary: "Remove a container",
        operationId: "Container.Delete",
        parameters: [
          parameter(
            :container_id,
            :path,
            %Schema{type: :string},
            "ID or name of the container. An initial segment of the id can be supplied if it uniquely determines the container.",
            required: true
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.IdResponse),
          404 =>
            response("no such container", "application/json", Schemas.ErrorResponse,
              example: %{message: "No such container: df6ed453357b"}
            ),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def remove(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "Content-Type", "application/json")

      case Container.destroy(conn.params.container_id) do
        {:ok, container_id} ->
          send_resp(conn, 200, Utils.id_response(container_id))

        {:error, :not_found} ->
          send_resp(conn, 404, Utils.error_response("no such container"))

        # Atm. the destroy api automatically stops a container. Docker Engine returns this error.
        # {:error, :already_started} ->
        #  send_resp(conn, 409, "you cannot remove a running container")

        unknown_msg ->
          Logger.warn("unknown error when destroying container #{inspect(unknown_msg)}")
          send_resp(conn, 500, Utils.error_response("server error"))
      end
    end
  end

  defmodule Start do
    use Plug.Builder
    alias Jocker.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.Start"
    )

    plug(:start)

    def open_api_operation(_) do
      %Operation{
        # tags: ["users"],
        summary: "Start a container",
        operationId: "Container.Start",
        parameters: [
          parameter(
            :container_id,
            :path,
            %Schema{type: :string},
            "ID or name of the container. An initial segment of the id can be supplied if it uniquely determines the container.",
            required: true
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.IdResponse),
          304 => response("container already started", "application/json", Schemas.ErrorResponse),
          404 =>
            response("no such container", "application/json", Schemas.ErrorResponse,
              example: %{message: "No such container: df6ed453357b"}
            ),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def start(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "Content-Type", "application/json")

      case Container.start(conn.params.container_id) do
        {:ok, %Container{id: container_id}} ->
          send_resp(conn, 200, Jason.encode!(%{id: container_id}))

        {:error, :not_found} ->
          send_resp(conn, 404, Utils.error_response("no such container"))

        {:error, :already_started} ->
          send_resp(conn, 304, Utils.error_response("container already started"))

        _ ->
          send_resp(conn, 500, Utils.error_response("server error"))
      end
    end
  end

  defmodule Stop do
    use Plug.Builder
    alias Jocker.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Container.Stop"
    )

    plug(:stop)

    def open_api_operation(_) do
      %Operation{
        summary: "Stop a container",
        operationId: "Container.Stop",
        parameters: [
          parameter(
            :container_id,
            :path,
            %Schema{type: :string},
            "ID or name of the container. An initial segment of the id can be supplied if it uniquely determines the container.",
            required: true
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.IdResponse),
          304 => response("container already stopped", "application/json", Schemas.ErrorResponse),
          404 =>
            response("no such container", "application/json", Schemas.ErrorResponse,
              example: %{message: "no such container"}
            ),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def stop(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "Content-Type", "application/json")

      case Container.stop(conn.params.container_id) do
        {:ok, %Container{id: id}} ->
          send_resp(conn, 200, Utils.id_response(id))

        {:error, :not_found} ->
          send_resp(conn, 404, Utils.error_response("no such container"))

        {:error, :not_running} ->
          send_resp(conn, 304, Utils.error_response("container already stopped"))

        _ ->
          send_resp(conn, 500, Utils.error_response("server error"))
      end
    end
  end
end
