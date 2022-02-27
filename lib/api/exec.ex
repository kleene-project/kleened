defmodule Jocker.API.Exec do
  alias OpenApiSpex.{Operation, Schema}
  alias Jocker.Engine.Exec
  alias Jocker.API.Schemas
  require Logger

  import OpenApiSpex.Operation,
    only: [parameter: 5, request_body: 4, response: 3, response: 4]

  defmodule Create do
    use Plug.Builder
    alias Jocker.API.Utils

    plug(Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason
    )

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Exec.Create"
    )

    plug(:create)

    def open_api_operation(_) do
      %Operation{
        summary: "Create an execution instance",
        operationId: "Exec.Create",
        requestBody:
          request_body(
            "Configuration to use when creating the execution instance",
            "application/json",
            Schemas.ExecConfig,
            required: true
          ),
        responses: %{
          201 => response("no error", "application/json", Schemas.IdResponse),
          404 => response("container not found", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def create(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "Content-Type", "application/json")

      exec_config = conn.body_params

      case Exec.create(exec_config) do
        {:ok, exec_id} ->
          send_resp(conn, 201, Utils.id_response(exec_id))

        {:error, msg} ->
          send_resp(conn, 404, Utils.error_response(msg))

        unknown_msg ->
          Logger.warn("unknown error creating container: #{inspect(unknown_msg)}")
          send_resp(conn, 500, Utils.error_response("server error"))
      end
    end
  end

  defmodule Stop do
    use Plug.Builder
    alias Jocker.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Exec.Stop"
    )

    plug(:stop)

    def open_api_operation(_) do
      %Operation{
        summary: "Stop and/or destroy a execution instance.",
        operationId: "Exec.Stop",
        parameters: [
          parameter(
            :exec_id,
            :path,
            %Schema{type: :string},
            "Id of the execution instance.",
            required: true
          ),
          parameter(
            :force_stop,
            :query,
            %Schema{type: :boolean},
            "Whether or not to force stop the running process (using 'kill -9')",
            required: true
          ),
          parameter(
            :stop_container,
            :query,
            %Schema{type: :boolean},
            "Whether or not to stop the entire container or just the specific execution instance",
            required: true
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.IdResponse),
          404 =>
            response("no such container", "application/json", Schemas.ErrorResponse,
              example: %{message: "container not running"}
            ),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def stop(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      conn = Plug.Conn.put_resp_header(conn, "Content-Type", "application/json")
      stop_container = conn.query_params["stop_container"]
      force_stop = conn.query_params["force_stop"]
      exec_id = conn.params.exec_id

      case Exec.stop(exec_id, %{stop_container: stop_container, force_stop: force_stop}) do
        {:ok, _msg} ->
          send_resp(conn, 200, Utils.id_response(exec_id))

        {:error, _msg} ->
          send_resp(conn, 404, Utils.error_response("no such container"))

        _ ->
          send_resp(conn, 500, Utils.error_response("server error"))
      end
    end
  end
end
