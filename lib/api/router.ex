defmodule Jocker.API.Router do
  use Plug.Router
  use Plug.Debugger
  require Logger
  alias Jocker.API

  plug(Plug.Logger, log: :debug)
  plug(OpenApiSpex.Plug.PutApiSpec, module: Jocker.API.Spec)
  plug(:match)
  plug(:dispatch)

  # Containers:
  get("/containers/list", to: API.Container.List)
  post("/containers/create", to: API.Container.Create)
  delete("/containers/:container_id", to: API.Container.Remove)
  post("/containers/:container_id/start", to: API.Container.Start)
  post("/containers/:container_id/stop", to: API.Container.Stop)

  # Images:
  get("/images/list", to: API.Image.List)
  delete("/images/:image_id", to: API.Image.Remove)

  # Networks:
  get("/networks/list", to: API.Network.List)
  post("/networks/create", to: API.Network.Create)
  delete("/networks/:network_id", to: API.Network.Remove)
  post("/networks/:network_id/connect/:container_id", to: API.Network.Connect)
  post("/networks/:network_id/disconnect/:container_id", to: API.Network.Disconnect)

  # Volumes:
  get("/volumes/list", to: API.Volume.List)
  post("/volumes/create", to: API.Volume.Create)
  delete("/volumes/:volume_name", to: API.Volume.Remove)

  # "Default" route that will get called when no other route is matched
  match _ do
    send_resp(conn, 404, "not found")
  end

  def dispatch do
    # This is the root routing (cowboy-based) to seperate the rest API from the two websockets
    [
      {:_,
       [
         {"/containers/:container_id/attach", Jocker.Engine.HTTPContainerAttach, []},
         {"/images/build", Jocker.Engine.HTTPImageBuild, []},
         {:_, Plug.Cowboy.Handler, {Jocker.API.Router, []}}
       ]}
    ]
  end
end
