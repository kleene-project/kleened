defmodule Kleened.API.Network do
  alias OpenApiSpex.{Operation, Schema, Response}
  alias Kleened.Core.Network
  alias Kleened.API.Utils
  alias Kleened.API.Schemas
  require Logger

  import OpenApiSpex.Operation,
    only: [parameter: 5, response: 3, request_body: 4]

  defmodule List do
    use Plug.Builder

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Network.List"
    )

    plug(:list)

    def open_api_operation(_) do
      %Operation{
        summary: "network list",
        description: """
        Returns a list of networks. Use [network inspect endpoint](#operation/Network.Inspect)
        for detailed information about a specific network.

        Note that it uses a different, smaller representation of a network than
        inspecting a single network.
        """,
        operationId: "Network.List",
        responses: %{
          200 => response("no error", "application/json", Schemas.NetworkList),
          500 => response("server error", "application/json", Schemas.ErrorMessage)
        }
      }
    end

    def list(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      networks_json = Network.list() |> Jason.encode!()
      send_resp(conn, 200, networks_json)
    end
  end

  defmodule Create do
    use Plug.Builder

    plug(Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason
    )

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Network.Create"
    )

    plug(:create)

    def open_api_operation(_) do
      %Operation{
        # tags: ["users"],
        summary: "network create",
        description: "Create a network.",
        operationId: "Network.Create",
        requestBody:
          request_body(
            "Configuration used for the network.",
            "application/json",
            Schemas.NetworkConfig,
            required: true
          ),
        responses: %{
          201 => response("no error", "application/json", Schemas.IdMessage),
          409 => response("could not create network", "application/json", Schemas.ErrorMessage),
          500 => response("server error", "application/json", Schemas.ErrorMessage)
        }
      }
    end

    def create(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      options = conn.body_params

      case Network.create(options) do
        {:ok, %Schemas.Network{id: id}} ->
          send_resp(conn, 201, Utils.id_response(id))

        {:error, msg} ->
          Logger.info("Could not create network: #{msg}")
          send_resp(conn, 409, Utils.error_response(msg))
      end
    end
  end

  defmodule Remove do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Network.Remove"
    )

    plug(:remove)

    def open_api_operation(_) do
      %Operation{
        summary: "network remove",
        description: "Remove a network",
        operationId: "Network.Remove",
        parameters: [
          parameter(
            :network_id,
            :path,
            %Schema{type: :string},
            "ID or name of the network. An initial segment of the id can be supplied if it uniquely determines the network.",
            required: true
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.IdMessage),
          404 => response("no such network", "application/json", Schemas.ErrorMessage),
          500 => response("server error", "application/json", Schemas.ErrorMessage)
        }
      }
    end

    def remove(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      id = conn.params.network_id

      case Network.remove(id) do
        {:ok, id} ->
          send_resp(conn, 200, Utils.id_response(id))

        {:error, msg} ->
          send_resp(conn, 404, Utils.error_response(msg))
      end
    end
  end

  defmodule Connect do
    use Plug.Builder

    plug(Plug.Parsers,
      parsers: [:json],
      json_decoder: Jason
    )

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Network.Connect"
    )

    plug(:connect)

    def open_api_operation(_) do
      %Operation{
        summary: "network connect",
        description: "Connect a container to a network",
        operationId: "Network.Connect",
        parameters: [
          parameter(
            :network_id,
            :path,
            %Schema{type: :string},
            "ID or name of the network. An initial segment of the id can be supplied if it uniquely determines the network.",
            required: true
          )
        ],
        requestBody:
          request_body(
            "Connection configuration.",
            "application/json",
            Schemas.EndPointConfig,
            required: true
          ),
        responses: %{
          # 204 => response("operation was succesful", "application/json", Schemas.IdMessage),
          204 => %Response{description: "operation was succesful"},
          404 => response("no such network", "application/json", Schemas.ErrorMessage),
          409 =>
            response(
              "operation not possible with the present configuration",
              "application/json",
              Schemas.ErrorMessage
            ),
          500 => response("server error", "application/json", Schemas.ErrorMessage)
        }
      }
    end

    def connect(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      network_id = conn.params.network_id
      config = conn.body_params

      case Network.connect(network_id, config) do
        {:ok, _endpoint_config} ->
          send_resp(conn, 204, "")

        {:error, msg} ->
          case String.contains?(msg, "not found") do
            true -> send_resp(conn, 404, Utils.error_response(msg))
            false -> send_resp(conn, 409, Utils.error_response(msg))
          end
      end
    end
  end

  defmodule Disconnect do
    use Plug.Builder

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Network.Disconnect"
    )

    plug(:disconnect)

    def open_api_operation(_) do
      %Operation{
        summary: "network disconnect",
        description: "Disconnect a container from a network",
        operationId: "Network.Disconnect",
        parameters: [
          parameter(
            :network_id,
            :path,
            %Schema{type: :string},
            "ID or name of the network. An initial segment of the id can be supplied if it uniquely determines the network.",
            required: true
          ),
          parameter(
            :container_id,
            :path,
            %Schema{type: :string},
            "ID or name of the container. An initial segment of the id can be supplied if it uniquely determines the network.",
            required: true
          )
        ],
        responses: %{
          204 => %Response{description: "operation was succesful"},
          404 =>
            response(
              "no such network and/or container",
              "application/json",
              Schemas.ErrorMessage
            ),
          500 => response("server error", "application/json", Schemas.ErrorMessage)
        }
      }
    end

    def disconnect(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      network_id = conn.params.network_id
      container_id = conn.params.container_id

      case Network.disconnect(container_id, network_id) do
        :ok -> send_resp(conn, 204, "")
        {:error, msg} -> send_resp(conn, 409, Utils.error_response(msg))
      end
    end
  end
end
