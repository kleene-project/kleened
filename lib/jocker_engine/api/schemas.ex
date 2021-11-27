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

  defmodule NetworkConfig do
    OpenApiSpex.schema(%{
      description: "Network configuration",
      type: :object,
      properties: %{
        name: %Schema{
          type: :string,
          description: "Name of the network.",
          example: "westnet"
        },
        subnet: %Schema{
          type: :string,
          description: "The subnet (in CIDR-format) that is used for the network.",
          example: "10.13.37.0/24"
        },
        ifname: %Schema{
          type: :string,
          description: "Name of the interface that is being used for the network.",
          example: "jocker0"
        },
        driver: %Schema{
          type: :string,
          description: "Network type. Only 'loopback' type of network is supported.",
          example: "loopback"
        }
      },
      required: [:name]
    })
  end

  defmodule VolumeConfig do
    OpenApiSpex.schema(%{
      description: "Volume configuration",
      type: :object,
      properties: %{
        name: %Schema{type: :string, description: "Name of the volume."}
      },
      required: [:name]
    })
  end

  defmodule Image do
    OpenApiSpex.schema(%{
      description: "the image metadata",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of the image", type: :string},
        name: %Schema{description: "Name of the image", type: :string},
        tag: %Schema{description: "Tag of the image", type: :string},
        command: %Schema{
          description: "Default command used when creating a container from this image",
          type: :array,
          items: %Schema{type: :string},
          example: ["/bin/sh", "-c", "/bin/ls"]
        },
        env_vars: %Schema{
          description:
            "List of environment variables and their values to set before running command.",
          type: :array,
          items: %Schema{type: :string},
          example: ["PWD=/roo/", "JAIL_MGMT_ENGINE=jocker"]
        },
        layer_id: %Schema{description: "Id of the layer containing the image", type: :string},
        user: %Schema{description: "user used when executing the command", type: :string},
        created: %Schema{description: "When the image was created", type: :string}
      }
    })
  end

  defmodule NetworkSummary do
    # Atm. this is actually a mirror of the network itself
    OpenApiSpex.schema(%{
      description: "summary description of a network",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of the network", type: :string},
        name: %Schema{description: "Name of the network", type: :string},
        subnet: %Schema{description: "Subnet used for the network", type: :string},
        if_name: %Schema{
          description: "Name of the loopback interface used for the network",
          type: :string
        },
        driver: %Schema{
          description:
            "Which type of network is used. Possible values are 'loopback' where the network is situated on a loopback interface on the host, and 'host' where the container have inherited the hosts network configuration. Only one read-only network exists with the 'host' driver.",
          type: :string
        },
        default_gw_if: %Schema{
          description: "interface where the gateway can be reached",
          type: :boolean
        }
      }
    })
  end

  defmodule VolumeSummary do
    # Atm. this is actually a mirror of the volume itself
    OpenApiSpex.schema(%{
      description: "summary description of a volume",
      type: :object,
      properties: %{
        name: %Schema{description: "Name of the volume", type: :string},
        dataset: %Schema{description: "underlying zfs dataset of the volume", type: :string},
        mountpoint: %Schema{
          description: "main mountpoint of the volume (the mountpoint shown with 'zfs list')",
          type: :string
        },
        created: %Schema{description: "when the volume was created", type: :string}
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
