defmodule Kleened.API.Schemas do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule ContainerConfig do
    OpenApiSpex.schema(%{
      summary:
        "Configuration for a container. Some of the configuration parameters will overwrite the corresponding parameters in the specified image.",
      type: :object,
      properties: %{
        name: %Schema{
          description: "Name of the container. Must match `/?[a-zA-Z0-9][a-zA-Z0-9_.-]+`.",
          type: :string,
          nullable: true
        },
        image: %Schema{
          type: :string,
          description: """
          The name or id and possibly a snapshot of the image used for creating the container.
          The parameter uses the followinge format:

          - `<image_id>[:@<snapshot_id>]` or
          - `<name>[:<tag>][:@<snapshot_id>]`.

          If `<tag>` is omitted, `latest` is assumed.
          """,
          example: [
            "FreeBSD:13.2-STABLE",
            "FreeBSD:13.2-STABLE:@6b3c821605d4",
            "48fa55889b0f",
            "48fa55889b0f:@2028818d6f06"
          ]
        },
        cmd: %Schema{
          description:
            "Command to execute when the container is started. If no command is specified the command from the image is used.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          nullable: true,
          example: ["/bin/sh", "-c", "ls /"]
        },
        user: %Schema{
          type: :string,
          description: """
          User that executes the command (cmd).
          If no user is set, the user from the image will be used, which in turn is 'root' if no user is specified there.

          This parameter will be overwritten by the jail parameter `exec.jail_user` if it is set.
          """,
          nullable: true,
          default: ""
        },
        env: %Schema{
          description:
            "List of environment variables when using the container. This list will be merged with environment variables defined by the image. The values in this list takes precedence if the variable is defined in both.",
          type: :array,
          items: %Schema{type: :string},
          nullable: true,
          default: [],
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
        },
        volumes: %Schema{
          description: "List of volumes that should be mounted into the container",
          type: :array,
          items: %Schema{type: :string},
          nullable: true,
          default: []
        },
        jail_param: %Schema{
          description: """
          List of jail parameters to use for the container.
          See the [`jails manual page`](https://man.freebsd.org/cgi/man.cgi?query=jail) for details.

          A few parameters have some special behavior in Kleene:

          - `exec.jail_user`: If not explicitly set, the value of the `user` parameter will be used.
          - `mount.devfs`/`exec.clean`: If not explicitly set, `mount.devfs=true`/`exec.clean=true` will be used.

          So, if you do not want `exec.clean` and `mount.devfs` enabled, you must actively disable them.
          """,
          type: :array,
          items: %Schema{type: :string},
          nullable: true,
          default: [],
          example: ["allow.raw_sockets=true", "osrelease=kleenejail"]
        }
      }
    })
  end

  defmodule Container do
    OpenApiSpex.schema(%{
      description: "summary description of a container",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of the container", type: :string},
        name: %Schema{description: "Name of the container.", type: :string},
        image_id: %Schema{
          description: "The id of the image that this container was created from",
          type: :string
        },
        command: %Schema{
          description: "Command being used when starting the container",
          type: :array,
          items: %Schema{type: :string},
          default: []
        },
        layer_id: %Schema{
          description: "The id of the layer used by the container.",
          type: :string
        },
        user: %Schema{
          description:
            "The default user used when creating execution instances in the container.",
          type: :string
        },
        env: %Schema{
          description:
            "List of environment variables used when the container is used. This list will be merged with environment variables defined by the image. The values in this list takes precedence if the variable is defined in both places.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
        },
        jail_param: %Schema{
          description: "List of jail parameters (see jail(8) for details)",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["allow.raw_sockets=true", "osrelease=kleenejail"]
        },
        created: %Schema{description: "When the container was created", type: :string},
        running: %Schema{description: "whether or not the container is running", type: :boolean}
      }
    })
  end

  defmodule ExecConfig do
    OpenApiSpex.schema(%{
      description:
        "Configuration of an executable to run within a container. Some of the configuration parameters will overwrite the corresponding parameters if they are defined in the container.",
      type: :object,
      properties: %{
        container_id: %Schema{
          type: :string,
          description: "Id of the container used for creating the exec instance."
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
            "User that executes the command in the container. If no user is set the user from the container will be used.",
          default: ""
        },
        env: %Schema{
          description: """
          A list of environment variables in the form `["VAR=value", ...]` that is set when the command is executed.
          This list will be merged with environment variables defined by the container.
          The values in this list takes precedence if the variable is defined in both places.",
          """,
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
        },
        tty: %Schema{description: "Allocate a pseudo-TTY", type: :boolean, default: false}
      }
    })
  end

  defmodule ExecStartConfig do
    OpenApiSpex.schema(%{
      description: "Options for starting an execution instance.",
      type: :object,
      properties: %{
        exec_id: %Schema{
          type: :string,
          description: "id of the execution instance to start"
        },
        attach: %Schema{
          description: "Whether to receive output from `stdin` and `stderr`.",
          type: :boolean
        },
        start_container: %Schema{
          type: :boolean,
          description: "Whether to start the container if it is not running."
        }
      },
      required: [:exec_id, :attach, :start_container]
    })
  end

  defmodule EndPointConfig do
    OpenApiSpex.schema(%{
      description: "Configuration of a connection between a network to a container.",
      type: :object,
      properties: %{
        container: %Schema{
          type: :string,
          description: "Name or (possibly truncated) id of the container"
        },
        ip_address: %Schema{
          type: :string,
          description:
            "The ip(v4) address that should be assigned to the container. If this field is not set (or null) an unused ip contained in the subnet is auto-generated.",
          default: nil,
          example: "10.13.37.33"
        }
      },
      required: [:container]
    })
  end

  defmodule EndPoint do
    OpenApiSpex.schema(%{
      description: "Endpoint connecting a container to a network.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "EndPoint ID"},
        network: %Schema{
          type: :string,
          description: "Name of the network that this endpoint belongs to."
        },
        container: %Schema{
          type: :string,
          description: "ID of the container that this endpoint belongs to."
        },
        epair: %Schema{
          description: "epair used for endpoint in case of a VNET network",
          type: :string,
          nullable: true
        },
        ip_address: %Schema{
          description: "IP address of the container connected to the network",
          type: :string,
          nullable: true
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
          description:
            "Name of the loopback interface that is being used for the network. Only used with the 'loopback' driver.",
          example: "kleene0"
        },
        driver: %Schema{
          type: :string,
          description: """
          Which driver to use for the network. Possible values are 'vnet', 'loopback', and 'host'.
          See jails(8) and the networking documentation for details.
          """,
          example: "vnet"
        }
      },
      required: [:name, :subnet, :driver]
    })
  end

  defmodule ImageBuildConfig do
    OpenApiSpex.schema(%{
      description: "Configuration for an image build.",
      type: :object,
      properties: %{
        context: %Schema{
          type: :string,
          description: "Path on the Kleened host of the context that is used for the build."
        },
        dockerfile: %Schema{
          type: :string,
          description:
            "Path of the Dockerfile used for the build. The path is relative to the context path.",
          default: "Dockerfile"
        },
        quiet: %Schema{
          type: :boolean,
          description: "Whether or not to emit status messages of the build process.",
          default: false
        },
        cleanup: %Schema{
          type: :boolean,
          description: "Whether or not to remove the image in case of a build failure.",
          default: true
        },
        tag: %Schema{
          type: :string,
          description:
            "A name and optional tag to apply to the image in the name:tag format. If you omit the tag the default latest value is assumed.",
          default: ""
        },
        buildargs: %Schema{
          description:
            "Object of string pairs for build-time ARG-variables. Kleened uses the buildargs as the environment variables for, e.g., the RUN instruction, or for variable expansion in other Dockerfile instructions. This is not meant for passing secret values.",
          type: :object,
          default: %{},
          example: %{"USERNAME" => "Stephen", "JAIL_MGMT_ENGINE" => "kleene"}
        }
      },
      required: [:context]
    })
  end

  defmodule ImageCreateConfig do
    OpenApiSpex.schema(%{
      description: "Configuration for the creation of base images.",
      type: :object,
      required: [:method],
      properties: %{
        method: %Schema{
          description: """
          There are two methods for creating a new base image:

          - `\"fetch\"`: Kleened will fetch a release/snapshot of the base system and use it for image creation.
          - `\"zfs\"`: A copy of the `zfs_dataset` is used for the image.
          """,
          type: :string,
          enum: ["fetch", "zfs"]
        },
        tag: %Schema{
          description: "Name and optionally a tag in the `name:tag` format",
          type: :string,
          default: ""
        },
        dns: %Schema{
          description:
            "Whether or not to copy `/etc/resolv.conf` from the host to the new image.",
          type: :boolean,
          default: true
        },
        zfs_dataset: %Schema{
          description:
            "Dataset path on the host used for the image (required for method `\"zfs\"` only).",
          type: :string,
          default: ""
        },
        url: %Schema{
          description:
            "URL to a remote location where the base system (as a base.txz file) is stored. If an empty string is supplied kleened will try to fetch a version of the base sytem from download.freebsd.org using information from `uname(1)` (required for method 'fetch').",
          type: :string,
          default: ""
        },
        force: %Schema{
          description:
            "Ignore any discrepancies detected when using `uname(1)` to fetch the base system (method `\"fetch\"` only).",
          type: :boolean,
          default: false
        }
      }
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
          default: [],
          example: ["/bin/sh", "-c", "/bin/ls"]
        },
        env: %Schema{
          description: "Environment variables and their values to set before running command.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["PWD=/roo/", "JAIL_MGMT_ENGINE=kleene"]
        },
        buildargs: %Schema{
          description:
            "Object of string pairs for build-time variables. Users pass these values at build-time. Kleened uses the buildargs as the environment context for commands run via the Dockerfile RUN instruction, or for variable expansion in other Dockerfile instructions. This is not meant for passing secret values.",
          type: :object,
          default: %{},
          example: %{"USERNAME" => "Stephen", "JAIL_MGMT_ENGINE" => "kleene"}
        },
        layer_id: %Schema{description: "Id of the layer containing the image", type: :string},
        user: %Schema{description: "user used when executing the command", type: :string},
        instructions: %Schema{
          description: """
          Instructions and their corresponding snapshots, if any, used for creating the image.
          Each item in the array is comprised of a 2-element array of the form `["<instruction>","<snapshot>"]`
          containing a instruction and its snapshot.
          The latter will only be present if it is a `RUN` or `COPY` instruction that executed succesfully.
          Otherwise `<snapshot>` will be an empty string.
          """,
          type: :array,
          items: %Schema{type: :array, items: %Schema{type: :string}},
          default: [],
          example: []
        },
        created: %Schema{description: "When the image was created", type: :string}
      }
    })
  end

  defmodule ImageList do
    OpenApiSpex.schema(%{
      description: "List of images.",
      type: :array,
      items: Kleened.API.Schemas.Image
    })
  end

  defmodule Network do
    OpenApiSpex.schema(%{
      description: "summary description of a network",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of the network", type: :string},
        name: %Schema{description: "Name of the network", type: :string},
        subnet: %Schema{description: "Subnet used for the network", type: :string},
        driver: %Schema{
          description: "Type of network.",
          type: :string
        },
        loopback_if: %Schema{
          description: "Name of the loopback interface (used for a 'loopback' network).",
          type: :string,
          default: ""
        },
        bridge_if: %Schema{
          description: "Name of the bridge interface (used for a 'vnet' network).",
          type: :string,
          default: ""
        }
      }
    })
  end

  defmodule NetworkList do
    OpenApiSpex.schema(%{
      description: "List of networks.",
      type: :array,
      items: Kleened.API.Schemas.Network
    })
  end

  defmodule NetworkInspect do
    OpenApiSpex.schema(%{
      description: "Detailed information on a volume.",
      type: :object,
      properties: %{
        network: Kleened.API.Schemas.Network,
        network_endpoints: %Schema{
          type: :array,
          description: "Endpoints of the network.",
          items: Kleened.API.Schemas.EndPoint
        }
      }
    })
  end

  defmodule Volume do
    OpenApiSpex.schema(%{
      description: "Volume object used for persistent storage in containers.",
      type: :object,
      properties: %{
        name: %Schema{description: "Name of the volume", type: :string},
        dataset: %Schema{description: "underlying zfs dataset of the volume", type: :string},
        mountpoint: %Schema{
          description:
            "mountpoint of the volume's underlying zfs-dataset (the mountpoint shown with 'zfs list')",
          type: :string
        },
        created: %Schema{description: "when the volume was created", type: :string}
      }
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

  defmodule MountPoint do
    OpenApiSpex.schema(%{
      description: "Detailed information on a volume.",
      type: :object,
      properties: %{
        container_id: %Schema{
          type: :string,
          description: "ID of the container where the volume is mounted."
        },
        volume_name: %Schema{type: :string, description: "Name of the volume"},
        location: %Schema{
          type: :string,
          description: "Location of the mount within the container."
        },
        read_only: %Schema{type: :boolean, description: "Whether this mountpoint is read-only."}
      }
    })
  end

  defmodule VolumeInspect do
    OpenApiSpex.schema(%{
      description: "Detailed information on a volume.",
      type: :object,
      properties: %{
        volume: Kleened.API.Schemas.Volume,
        mountpoints: %Schema{
          type: :array,
          description: "Mountpoints of the volume.",
          items: Kleened.API.Schemas.MountPoint
        }
      }
    })
  end

  defmodule VolumeList do
    OpenApiSpex.schema(%{
      description: "List of volumes.",
      type: :array,
      items: Kleened.API.Schemas.Volume
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

  defmodule ContainerSummaryList do
    OpenApiSpex.schema(%{
      description: "List of summarised containers.",
      type: :array,
      items: Kleened.API.Schemas.ContainerSummary
    })
  end

  defmodule ContainerInspect do
    OpenApiSpex.schema(%{
      description: "Detailed information on a container.",
      type: :object,
      properties: %{
        container: Kleened.API.Schemas.Container,
        container_endpoints: %Schema{
          type: :array,
          description: "Endpoints of the container.",
          items: Kleened.API.Schemas.EndPoint
        },
        container_mountpoints: %Schema{
          type: :array,
          description: "Mountpoints of the container.",
          items: Kleened.API.Schemas.MountPoint
        }
      }
    })
  end

  defmodule WebSocketMessage do
    OpenApiSpex.schema(%{
      description: "The request have been validated and the request is being processed.",
      type: :object,
      properties: %{
        msg_type: %Schema{
          description: "Which type of message.",
          type: :string,
          enum: ["starting", "closing", "error"]
        },
        message: %Schema{
          description: "A useful message to tell the client what has happened.",
          type: :string,
          default: ""
        },
        data: %Schema{
          description:
            "Any data that might have been created by the process such as an image id.",
          type: :string,
          default: ""
        }
      },
      required: [:msg_type, :message, :data],
      example: %{
        msg_type: "closing",
        message: "succesfully started execution instance in detached mode",
        data: ""
      }
    })
  end

  defmodule ErrorResponse do
    OpenApiSpex.schema(%{
      description: "Represents an error and (possibly) its reason.",
      type: :object,
      properties: %{
        message: %Schema{
          description: "The error message, if any.",
          type: :string,
          nullable: false
        }
      },
      example: %{
        message: "Something went wrong."
      },
      required: [:message]
    })
  end

  defmodule IdResponse do
    OpenApiSpex.schema(%{
      title: "IdResponse",
      description: "Response to an API call that returns just an Id",
      type: :object,
      properties: %{
        id: %Schema{
          description: "The id of the created/modified/destroyed object.",
          type: :string,
          nullable: false
        }
      },
      required: [:id]
    })
  end

  defmodule IdListResponse do
    OpenApiSpex.schema(%{
      title: "IdListResponse",
      description: "Response to an API call that returns just an Id",
      type: :array,
      items: %Schema{type: :string}
    })
  end
end
