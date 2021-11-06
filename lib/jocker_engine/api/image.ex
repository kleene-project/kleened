defmodule Jocker.Engine.API.Image do
  alias OpenApiSpex.{Operation, Schema}
  alias Jocker.Engine
  alias Jocker.Engine.API.Utils
  alias Jocker.Engine.API.Schemas
  require Logger

  import OpenApiSpex.Operation,
    only: [parameter: 5, response: 3]

  defmodule List do
    use Plug.Builder

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Image.List"
    )

    plug(:list)

    def open_api_operation(_) do
      %Operation{
        # tags: ["users"],
        summary: "List images",
        description: "Returns a list of images.",
        operationId: "Image.List",
        responses: %{
          200 =>
            response("no error", "application/json", %Schema{
              type: :array,
              items: Schemas.Image
            })
        }
      }
    end

    def list(conn, _opts) do
      image_list = Jocker.Engine.MetaData.list_images() |> Jason.encode!()

      conn
      |> Plug.Conn.put_resp_header("Content-Type", "application/json")
      |> Plug.Conn.send_resp(200, image_list)
    end
  end

  defmodule Remove do
    use Plug.Builder

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Image.List"
    )

    plug(:remove)

    def open_api_operation(_) do
      %Operation{
        # tags: ["users"],
        summary: "Remove image",
        description: "Returns a list of images.",
        operationId: "Image.Remove",
        parameters: [
          parameter(
            :image_id,
            :path,
            %Schema{type: :string},
            "ID or name of the image. An initial segment of the id can be supplied if it uniquely determines the image.",
            required: true
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.IdResponse),
          404 => response("no such image", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def remove(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "Content-Type", "application/json")
      image_id = conn.params.image_id

      case Engine.Image.destroy(image_id) do
        :ok ->
          Plug.Conn.send_resp(conn, 200, Utils.id_response(image_id))

        :not_found ->
          msg = "Error: No such image: #{image_id}\n"
          Plug.Conn.send_resp(conn, 404, Utils.error_response(msg))
      end
    end
  end
end
