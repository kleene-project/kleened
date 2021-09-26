defmodule Jocker.Engine.API.Container do
  alias OpenApiSpex.{Operation, Schema}
  alias Jocker.Engine.API.Schemas

  import OpenApiSpex.Operation,
    only: [parameter: 4, parameter: 5, request_body: 4, response: 3, response: 4]

  defmodule List do
    use Plug.Builder

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "UserHandler.Index"
    )

    plug(:list)

    def open_api_operation(_) do
      %Operation{
        # tags: ["users"],
        summary: "List containers",
        description: "Returns a compact listing of containers.",
        operationId: "ContainerList",
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

      container_list = Engine.Container.list(opts) |> Jason.encode!()

      conn
      |> Plug.Conn.put_resp_header("Content-Type", "application/json")
      |> Plug.Conn.send_resp(conn, 200, container_list)
    end
  end

  defmodule Create do
    use Plug.Builder

    plug(:create)

    def open_api_operation(_) do
      %Operation{
        summary: "Start a container",
        operationId: "ContainerStart",
        parameters: [
          parameter(:id, :path, %Schema{type: :string}, "ID or name of the container",
            required: true
          )
        ],
        responses: %{
          # FIXME: Hertil!
          204 =>
            response("no error", "application/json", %Schema{
              type: :array,
              items: Schemas.ContainerSummary
            })
        }
      }
    end

    def create(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      conn = fetch_query_params(conn)

      name_opt =
        case conn.query_params do
          %{"name" => name} -> [name: name]
          _ -> []
        end

      opts = [name_opt | Jason.decode!(body, keys: :atoms!) |> Map.to_list()]

      return_body =
        case Engine.Container.create(opts) do
          {:ok, container} -> Jason.encode!(container)
          {:error, error} -> Jason.encode!(error)
        end

      IO.inspect(return_body)

      send_resp(conn, 201, return_body)
    end
  end

  defmodule Remove do
    use Plug.Builder
    plug(:remove)

    def open_api_operation(_) do
    end

    def remove(conn, _opts) do
      case Engine.Container.destroy(conn.path_params.container_id) do
        :ok ->
          send_resp(conn, 204, "")

        {:error, :not_found} ->
          send_resp(conn, 404, "no such container")

        # FIXME: Atm. the destroy api automatically stops a container. Docker Engine returns this error.
        # {:error, :already_started} ->
        #  send_resp(conn, 409, "you cannot remove a running container")

        _ ->
          send_resp(conn, 500, "server error")
      end
    end
  end

  defmodule Start do
    use Plug.Builder
    plug(:start)

    def open_api_operation(_) do
      %Operation{
        # tags: ["users"],
        summary: "Start a container",
        operationId: "ContainerStart",
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
          204 => response("no error", "application/json", Schemas.IdResponse),
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
      case Engine.Container.start(conn.path_params.container_id) do
        {:ok, container_id} ->
          send_resp(conn, 204, container_id)

        {:error, :not_found} ->
          send_resp(conn, 404, "{\"message\": \"no such container\"}")

        {:error, :already_started} ->
          send_resp(conn, 304, "{\"message\": \"container already started\"}")

        _ ->
          send_resp(conn, 500, "{\"message\": \"server error\"}")
      end
    end
  end

  defmodule Stop do
    use Plug.Builder
    plug(:stop)

    def open_api_operation(_) do
    end

    def stop(conn, _opts) do
      case Engine.Container.stop(conn.path_params.container_id) do
        {:ok, container_id} ->
          send_resp(conn, 204, container_id)

        {:error, :not_found} ->
          send_resp(conn, 404, "no such container")

        {:error, :not_running} ->
          send_resp(conn, 304, "container already stopped")

        _ ->
          send_resp(conn, 500, "server error")
      end
    end
  end
end
