defmodule Kleened.API.Volume do
  alias OpenApiSpex.{Operation, Schema}
  alias Kleened.API.Schemas
  alias Kleened.Core.Volume
  require Logger

  import OpenApiSpex.Operation,
    only: [parameter: 5, request_body: 4, response: 3]

  defmodule List do
    use Plug.Builder

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Volume.List"
    )

    plug(:list)

    def open_api_operation(_) do
      %Operation{
        summary: "volume list",
        description: "Returns a compact listing of existing volumes.",
        operationId: "Volume.List",
        responses: %{
          200 => response("no error", "application/json", Schemas.VolumeList)
        }
      }
    end

    def list(conn, _opts) do
      volumes = Kleened.Core.MetaData.list_volumes() |> Jason.encode!()

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.send_resp(200, volumes)
    end
  end

  defmodule Create do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason
    )

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Volume.Create"
    )

    plug(:create)

    def open_api_operation(_) do
      %Operation{
        summary: "volume create",
        description:
          "Create a volume. The underlying volume zfs dataset will be located at `{kleened root path}/volumes`.",
        operationId: "Volume.Create",
        requestBody:
          request_body(
            "Volume configuration to use when creating the volume",
            "application/json",
            Schemas.VolumeConfig,
            required: true
          ),
        responses: %{
          201 => response("volume created", "application/json", Schemas.IdMessage),
          500 => response("server error", "application/json", Schemas.ErrorMessage)
        }
      }
    end

    def create(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")

      name = conn.body_params.name
      %Schemas.Volume{} = Volume.create(name)
      send_resp(conn, 201, Utils.id_response(name))
    end
  end

  defmodule Remove do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Volume.Remove"
    )

    plug(:remove)

    def open_api_operation(_) do
      %Operation{
        summary: "volume remove",
        description: "Remove a volume",
        operationId: "Volume.Remove",
        parameters: [
          parameter(
            :volume_name,
            :path,
            %Schema{type: :string},
            "Name of the volume",
            required: true
          )
        ],
        responses: %{
          200 => response("volume removed", "application/json", Schemas.IdMessage),
          404 => response("no such volume", "application/json", Schemas.ErrorMessage),
          500 => response("server error", "application/json", Schemas.ErrorMessage)
        }
      }
    end

    def remove(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      name = conn.params.volume_name

      case Volume.destroy(name) do
        :ok ->
          send_resp(conn, 200, Utils.id_response(name))

        {:error, msg} ->
          send_resp(conn, 404, Utils.error_response(msg))
      end
    end
  end
end
