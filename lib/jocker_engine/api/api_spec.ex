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
        # FIXME: no handler made for this
        # "/v0.0.1/containers/create" =>
        #  OpenApiSpex.PathItem.from_routes([
        #    %{verb: :post, plug: API.Container.Create, opts: []}
        #  ]),
        "/containers/list" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :get, plug: API.Container.List, opts: []}
            # %{verb: :post, plug: PlugApp.UserHandler.Create, opts: []}
          ]),
        "/containers/{id}/start" =>
          OpenApiSpex.PathItem.from_routes([
            %{verb: :post, plug: API.Container.Start, opts: []}
          ])
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
