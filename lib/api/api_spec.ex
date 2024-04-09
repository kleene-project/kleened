defmodule Kleened.API.Spec do
  alias OpenApiSpex.{Info, OpenApi}
  alias Kleened.API
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Kleened API",
        description: "HTTP API for communicating with Kleened",
        version: "0.0.1"
      },
      paths: %{
        "/containers/list" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.Container.List, opts: []}
          ]),
        "/containers/create" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Container.Create, opts: []}
          ]),
        "/containers/{container_id}" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :delete, plug: API.Container.Remove, opts: []}
          ]),
        "/containers/prune" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Container.Prune, opts: []}
          ]),
        "/containers/{container_id}/inspect" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.Container.Inspect, opts: []}
          ]),
        "/containers/{container_id}/update" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Container.Update, opts: []}
          ]),
        "/containers/{container_id}/stop" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Container.Stop, opts: []}
          ]),
        "/exec/create" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Exec.Create, opts: []}
          ]),
        # websocket
        "/exec/start" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.ExecStartWebSocket, opts: []}
          ]),
        "/exec/{exec_id}/stop" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Exec.Stop, opts: []}
          ]),
        # websocket
        "/images/build" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.ImageBuild, opts: []}
          ]),
        # websocket
        "/images/create" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.ImageCreate, opts: []}
          ]),
        "/images/{image_id}/tag" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Image.Tag, opts: []}
          ]),
        "/images/{image_id}/inspect" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.Image.Inspect, opts: []}
          ]),
        "/images/list" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.Image.List, opts: []}
          ]),
        "/images/{image_id}" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :delete, plug: API.Image.Remove, opts: []}
          ]),
        "/images/prune" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Image.Prune, opts: []}
          ]),
        "/networks/list" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.Network.List, opts: []}
          ]),
        "/networks/create" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Network.Create, opts: []}
          ]),
        "/networks/{network_id}" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :delete, plug: API.Network.Remove, opts: []}
          ]),
        "/networks/prune" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Network.Prune, opts: []}
          ]),
        "/networks/{network_id}/inspect" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.Network.Inspect, opts: []}
          ]),
        "/networks/connect" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Network.Connect, opts: []}
          ]),
        "/networks/{network_id}/disconnect/{container_id}" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Network.Disconnect, opts: []}
          ]),
        "/volumes/list" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.Volume.List, opts: []}
          ]),
        "/volumes/create" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Volume.Create, opts: []}
          ]),
        "/volumes/{volume_name}" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :delete, plug: API.Volume.Remove, opts: []}
          ]),
        "/volumes/prune" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Volume.Prune, opts: []}
          ]),
        "/volumes/{volume_name}/inspect" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.Volume.Inspect, opts: []}
          ])
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
