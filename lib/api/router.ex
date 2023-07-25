defmodule Kleened.API.Router do
  use Plug.Router
  use Plug.Debugger
  require Logger
  alias Kleened.API

  plug(Plug.Logger, log: :debug)
  plug(OpenApiSpex.Plug.PutApiSpec, module: Kleened.API.Spec)
  plug(:match)
  plug(:dispatch)

  # Containers:
  get("/containers/list", to: API.Container.List)
  post("/containers/create", to: API.Container.Create)
  delete("/containers/:container_id", to: API.Container.Remove)
  post("/containers/:container_id/stop", to: API.Container.Stop)

  # Execution instances
  post("/exec/create", to: API.Exec.Create)
  post("/exec/:exec_id/stop", to: API.Exec.Stop)

  # Images:
  get("/images/list", to: API.Image.List)
  delete("/images/:image_id", to: API.Image.Remove)

  # Networks:
  get("/networks/list", to: API.Network.List)
  post("/networks/create", to: API.Network.Create)
  delete("/networks/:network_id", to: API.Network.Remove)
  post("/networks/:network_id/connect", to: API.Network.Connect)
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
         {"/exec/:exec_id/start", API.ExecStartWebSocket, []},
         {"/images/build", API.ImageBuild, []},
         {"/images/create", API.ImageCreate, []},
         {:_, Plug.Cowboy.Handler, {Kleened.API.Router, []}}
       ]}
    ]
  end
end
