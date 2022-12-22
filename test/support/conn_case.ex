defmodule Jocker.API.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Plug.Test
      import Plug.Conn
      import OpenApiSpex.TestAssertions
      import OpenApiSpex.Schema, only: [example: 1]
    end
  end

  setup tags do
    # Added to the context to validate responses with assert_schema/3
    api_spec = Jocker.API.Spec.spec()

    {:ok, api_spec: api_spec}
  end
end
