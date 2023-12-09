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
          201 => response("volume created", "application/json", Schemas.IdResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
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
        description: """
        Remove one or more volumes. You cannot remove a volume that is in use by a container.
        """,
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
          200 => response("volume removed", "application/json", Schemas.IdResponse),
          404 => response("no such volume", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def remove(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      name = conn.params.volume_name

      case Volume.remove(name) do
        :ok ->
          send_resp(conn, 200, Utils.id_response(name))

        {:error, msg} ->
          send_resp(conn, 404, Utils.error_response(msg))
      end
    end
  end

  defmodule Prune do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Volume.Prune"
    )

    plug(:prune)

    def open_api_operation(_) do
      %Operation{
        summary: "volume prune",
        description: """
        Remove all volumes that are not being mounted into any containers.
        """,
        operationId: "Volume.Prune",
        responses: %{
          200 => response("volume removed", "application/json", Schemas.IdListResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def prune(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      {:ok, pruned_volumes} = Volume.prune()
      send_resp(conn, 200, Utils.idlist_response(pruned_volumes))
    end
  end

  defmodule Inspect do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Volume.Inspect"
    )

    plug(:inspect_)

    def open_api_operation(_) do
      %Operation{
        summary: "volume inspect",
        description: "Inspect a volume and its mountpoints.",
        operationId: "Volume.Inspect",
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
          200 => response("volume retrieved", "application/json", Schemas.VolumeInspect),
          404 => response("no such volume", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def inspect_(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      name = conn.params.volume_name

      case Volume.inspect_(name) do
        {:ok, volume_inspect} ->
          volume_inspect = Jason.encode!(volume_inspect)
          send_resp(conn, 200, volume_inspect)

        {:error, msg} ->
          msg_json = Utils.error_response(msg)
          send_resp(conn, 404, msg_json)
      end
    end
  end
end
