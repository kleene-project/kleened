defmodule Jocker.Engine.API.Spec do
  alias OpenApiSpex.{Info, OpenApi}
  alias Jocker.Engine.API
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Jocker Engine REST API.",
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
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
