defmodule Jocker.API.Spec do
  alias OpenApiSpex.{Info, OpenApi}
  alias Jocker.API
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Jockerd API",
        description: "HTTP API for communicating with the Jocker Engine",
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
        "/containers/{container_id}/start" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Container.Start, opts: []}
          ]),
        "/containers/{container_id}/stop" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Container.Stop, opts: []}
          ]),
        "/images/list" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.Image.List, opts: []}
          ]),
        "/images/{image_id}" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :delete, plug: API.Image.Remove, opts: []}
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
        "/networks/{network_id}/connect/{container_id}" =>
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
          ])
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
