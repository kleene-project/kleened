defmodule Jocker.API.Schemas do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule ContainerConfig do
    OpenApiSpex.schema(%{
      description:
        "Configuration for a container. Some of the configuration parameters will overwrite the corresponding parameters in the specified image.",
      type: :object,
      properties: %{
        image: %Schema{
          type: :string,
          description: "The name of the image to use when creating the container"
        },
        cmd: %Schema{
          description:
            "Command to execute when the container is started. If no command is specified the command from the image is used.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["/bin/sh", "-c", "ls /"]
        },
        user: %Schema{
          type: :string,
          description:
            "User that executes the command (cmd). If no user is set the user from the image will be used (which in turn is 'root' if no user is specified there).",
          default: ""
        },
        env: %Schema{
          description:
            "List of environment variables used when the container is used. This list will be merged with environment variables defined by the image. The values in this list takes precedence if the variable is defined in both places.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
        },
        volumes: %Schema{
          description: "List of volumes that should be mounted into the container",
          type: :array,
          items: %Schema{type: :string},
          default: []
        },
        networks: %Schema{
          description: "List of networks that the container should be connected to.",
          type: :array,
          items: %Schema{type: :string},
          default: []
        },
        jail_param: %Schema{
          description: "List of jail parameters (see jail(8) for details)",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["allow.raw_sockets=true", "osrelease=jockerjail"]
        }
      }
    })
  end

  defmodule ExecConfig do
    OpenApiSpex.schema(%{
      description:
        "Configuration of an executable to run within a container. Some of the configuration parameters will overwrite the corresponding parameters in the container.",
      type: :object,
      properties: %{
        container_id: %Schema{
          type: :string,
          description: "Id of the container that this exec instance belongs to."
        },
        cmd: %Schema{
          description:
            "Command to execute whithin the container. If no command is specified the command from the container is used.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["/bin/sh", "-c", "ls /"]
        },
        user: %Schema{
          type: :string,
          description:
            "User that executes the command. If no user is set the user from the container will be used.",
          default: ""
        },
        env: %Schema{
          description:
            "List of environment variables that is set when the command is executed. This list will be merged with environment variables defined by the container. The values in this list takes precedence iif the variable is defined in both places.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
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
          description:
            "Network type to use. Possible values are 'loopback' and 'vnet'. See the documentation on networking for details.",
          example: "loopback"
        }
      },
      required: [:name, :ifname, :subnet, :driver]
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
          description: "Type of network.",
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
