defmodule Kleened.API.Network do
  alias OpenApiSpex.{Operation, Schema, Response}
  alias Kleened.Core.Network
  alias Kleened.API.Utils
  alias Kleened.API.Schemas
  require Logger

  import OpenApiSpex.Operation,
    only: [parameter: 5, response: 3, request_body: 4]

  def network_identifier() do
    "Network identifier, i.e., the name, ID, or an initial unique segment of the ID."
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
          201 => response("no error", "application/json", Schemas.IdResponse),
          409 => response("could not create network", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
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
        Returns a list of networks.
        Use the [network inspect](#operation/Network.Inspect) endpoint
        to get detailed information about a network.
        """,
        operationId: "Network.List",
        responses: %{
          200 => response("no error", "application/json", Schemas.NetworkList),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def list(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      networks_json = Network.list() |> Jason.encode!()
      send_resp(conn, 200, networks_json)
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
        description: """
        Remove a network. Any connected containers will be disconnected.
        """,
        operationId: "Network.Remove",
        parameters: [
          parameter(
            :network_id,
            :path,
            %Schema{type: :string},
            Kleened.API.Network.network_identifier(),
            required: true
          )
        ],
        responses: %{
          200 => response("no error", "application/json", Schemas.IdResponse),
          404 => response("no such network", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
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

  defmodule Prune do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Network.Prune"
    )

    plug(:prune)

    def open_api_operation(_) do
      %Operation{
        summary: "network prune",
        description: """
        Remove all networks that are not used by any containers.
        """,
        operationId: "Network.Prune",
        responses: %{
          200 => response("network removed", "application/json", Schemas.IdListResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def prune(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      {:ok, pruned_networks} = Network.prune()
      send_resp(conn, 200, Utils.idlist_response(pruned_networks))
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
          # 204 => response("operation was succesful", "application/json", Schemas.IdResponse),
          204 => %Response{description: "operation was succesful"},
          404 => response("no such network", "application/json", Schemas.ErrorResponse),
          409 =>
            response(
              "operation not possible with the present configuration",
              "application/json",
              Schemas.ErrorResponse
            ),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
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
        description: """
        Disconnect a container from a network.

        The container must be stopped before it can be disconnected.
        """,
        operationId: "Network.Disconnect",
        parameters: [
          parameter(
            :network_id,
            :path,
            %Schema{type: :string},
            Kleened.API.Network.network_identifier(),
            required: true
          ),
          parameter(
            :container_id,
            :path,
            %Schema{type: :string},
            Kleened.API.Container.container_identifier(),
            required: true
          )
        ],
        responses: %{
          204 => %Response{description: "operation was succesful"},
          404 =>
            response(
              "no such network and/or container",
              "application/json",
              Schemas.ErrorResponse
            ),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
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

  defmodule Inspect do
    use Plug.Builder
    alias Kleened.API.Utils

    plug(OpenApiSpex.Plug.CastAndValidate,
      json_render_error_v2: true,
      operation_id: "Network.Inspect"
    )

    plug(:inspect_)

    def open_api_operation(_) do
      %Operation{
        summary: "network inspect",
        description: "Inspect a network and its endpoints.",
        operationId: "Network.Inspect",
        parameters: [
          parameter(
            :network_id,
            :path,
            %Schema{type: :string},
            Kleened.API.Network.network_identifier(),
            required: true
          )
        ],
        responses: %{
          200 => response("network retrieved", "application/json", Schemas.NetworkInspect),
          404 => response("no such network", "application/json", Schemas.ErrorResponse),
          500 => response("server error", "application/json", Schemas.ErrorResponse)
        }
      }
    end

    def inspect_(conn, _opts) do
      conn = Plug.Conn.put_resp_header(conn, "content-type", "application/json")
      network_ident = conn.params.network_id

      case Network.inspect_(network_ident) do
        {:ok, network_inspect} ->
          network_inspect = Jason.encode!(network_inspect)
          send_resp(conn, 200, network_inspect)

        {:error, msg} ->
          msg_json = Utils.error_response(msg)
          send_resp(conn, 404, msg_json)
      end
    end
  end
end
