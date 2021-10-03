defmodule Jocker.Engine.API.Schemas do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  # FIXME: Haven't used "examples: %{}" or "required: []" in the schema definitions.
  defmodule ContainerConfig do
    OpenApiSpex.schema(%{
      description: "Configuration for a container that is portable between hosts",
      type: :object,
      properties: %{
        image: %Schema{
          type: :string,
          description: "The name of the image to use when creating the container"
        },
        cmd: %Schema{
          type: :array,
          items: %Schema{type: :string},
          example: ["/bin/sh", "-c", "ls /"]
        },
        env: %Schema{
          description: "List of environment variables set when the command is executed",
          type: :array,
          items: %Schema{type: :string},
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
        },
        volumes: %Schema{
          description: "List of volumes that should be mounted into the container",
          type: :array,
          items: %Schema{type: :string}
        },
        networks: %Schema{
          description: "List of networks that the container should be connected to",
          type: :array,
          items: %Schema{type: :string}
        },
        jail_param: %Schema{
          description: "List of jail parameters (see jail(8) for details)",
          type: :array,
          items: %Schema{type: :string},
          example: ["allow.raw_sockets=true", "osrelease=jockerjail"]
        }
      }
    })
  end

  defmodule ContainerSummary do
    OpenApiSpex.schema(%{
      description: "summary description of a container",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of this container", type: :string},
        name: %Schema{description: "Name of the container", type: :string},
        image_id: %Schema{
          description: "The id of the image that this container was created from",
          type: :string
        },
        image_name: %Schema{
          description: "Name of the image that this container was created from",
          type: :string
        },
        image_tag: %Schema{
          description: "Tag of the image that this container was created from",
          type: :string
        },
        command: %Schema{
          description: "Command being used when starting the container",
          type: :string
        },
        created: %Schema{description: "When the container was created", type: :string},
        running: %Schema{description: "whether or not the container is running", type: :boolean}
      }
    })
  end

  defmodule ErrorResponse do
    OpenApiSpex.schema(%{
      description: "Represents an error",
      type: :object,
      properties: %{
        message: %Schema{description: "The error message.", type: "string", nullable: false}
      },
      example: %{
        message: "Something went wrong."
      },
      required: [:message]
    })
  end

  defmodule IdResponse do
    OpenApiSpex.schema(%{
      description: "Response to an API call that returns just an Id",
      type: :object,
      properties: %{
        id: %Schema{
          description: "The id of the created/modified/destroyed object.",
          type: "string",
          nullable: false
        }
      },
      required: [:id]
    })
  end
end
