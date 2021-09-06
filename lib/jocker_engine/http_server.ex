defmodule Jocker.Engine.HTTPServer do
  use Plug.Router
  use Plug.Debugger
  require Logger
  alias Jocker.Engine

  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:dispatch)

  get "/containers/list" do
    conn = fetch_query_params(conn)

    opts =
      case conn.query_params do
        %{"all" => "true"} -> [all: true]
        _ -> [all: false]
      end

    container_list = Engine.Container.list(opts) |> Jason.encode!()
    send_resp(conn, 200, container_list)
  end

  post "/containers/create" do
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

  delete "/containers/:container_id" do
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

  post "/containers/:container_id/start" do
    case Engine.Container.start(conn.path_params.container_id) do
      {:ok, container_id} ->
        send_resp(conn, 204, container_id)

      {:error, :not_found} ->
        send_resp(conn, 404, "no such container")

      {:error, :already_started} ->
        send_resp(conn, 304, "container already started")

      _ ->
        send_resp(conn, 500, "server error")
    end
  end

  post "/containers/:container_id/stop" do
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

  # "Default" route that will get called when no other route is matched
  match _ do
    send_resp(conn, 404, "not found")
  end
end
