defmodule Jocker.Engine.API.Router do
  use Plug.Router
  use Plug.Debugger
  require Logger
  alias Jocker.Engine.API

  plug(Plug.Logger, log: :debug)
  plug(:match)
  plug(:dispatch)

  get("/containers/list", to: API.Container.List)
  post("/containers/create", to: API.Container.Create)
  delete("/containers/:container_id", to: API.Container.Remove)
  post("/containers/:container_id/start", to: API.Container.Start)
  post("/containers/:container_id/stop", to: API.Container.Stop)

  # "Default" route that will get called when no other route is matched
  match _ do
    send_resp(conn, 404, "not found")
  end
end
