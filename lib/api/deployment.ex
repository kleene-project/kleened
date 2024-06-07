defmodule Kleened.API.Deployment do
  alias OpenApiSpex.Operation
  alias Kleened.API.Utils
  alias Kleened.API.Schemas
  alias Kleened.Core
  require Logger

  import OpenApiSpex.Operation,
    only: [request_body: 4, response: 3]

  defmodule Diff do
    use Plug.Builder

    plug(Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason
    )

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Deployment.Diff"
    )

    plug(:diff)

    def open_api_operation(_) do
      %Operation{
        summary: "deployment diff",
        description: """
        Create deployment.
        """,
        operationId: "Deployment.Diff",
        requestBody:
          request_body(
            "Deployment configuration.",
            "application/json",
            Schemas.DeploymentConfig,
            required: true
          ),
        responses: %{
          201 => response("no error", "application/json", nil),
          404 => response("error processing request", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def diff(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

      case Core.Deployment.diff(conn.body_params) do
        {:ok, result} ->
          send_resp(conn, 201, Jason.encode!(result))

        {:error, reason} ->
          send_resp(conn, 404, Utils.error_response(reason))
      end
    end
  end
end
