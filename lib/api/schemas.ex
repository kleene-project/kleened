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

          - `<image_id>[@<snapshot_id>]` or
          - `<name>[:<tag>][@<snapshot_id>]`.

          If `<tag>` is omitted, `latest` is assumed.
          """,
          example: [
            "FreeBSD:13.2-STABLE",
            "FreeBSD:13.2-STABLE@6b3c821605d4",
            "48fa55889b0f",
            "48fa55889b0f@2028818d6f06"
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
        mounts: %Schema{
          description:
            "List of files/directories/volumes on the host filesystem that should be mounted into the container.",
          type: :array,
          items: Kleened.API.Schemas.MountPointConfig,
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
        },
        network_driver: %Schema{
          type: :string,
          description: """
          What kind of network driver should the container use.
          Possible values are `ipnet`, `host`, `vnet`, `disabled`.
          """,
          default: "ipnet",
          example: "host",
          enum: ["ipnet", "host", "vnet", "disabled"]
        }
      }
    })
  end

  defmodule Container do
    OpenApiSpex.schema(%{
      description: "Summary description of a container",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of the container", type: :string},
        name: %Schema{description: "Name of the container.", type: :string},
        image_id: %Schema{
          description: "The id of the image that this container was created from",
          type: :string
        },
        cmd: %Schema{
          description: "Command being used when starting the container",
          type: :array,
          items: %Schema{type: :string},
          default: []
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
        network_driver: %Schema{
          type: :string,
          description: """
          What kind of network driver is the container using.
          Possible values are `ipnet`, `host`, `vnet`, `disabled`.
          """,
          example: "ipnet",
          enum: ["ipnet", "host", "vnet", "disabled"]
        },
        jail_param: %Schema{
          description: "List of jail parameters (see jail(8) for details)",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["allow.raw_sockets=true", "osrelease=kleenejail"]
        },
        created: %Schema{description: "When the container was created", type: :string},
        dataset: %Schema{description: "ZFS dataset of the container", type: :string},
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
        type: %Schema{
          type: :string,
          description: """
          What kind of network should be created. Possible values are 'bridge', 'loopback', and 'custom'.
          """,
          example: "bridge",
          enum: ["bridge", "loopback", "custom"]
        },
        interface: %Schema{
          type: :string,
          description: """
          Name of the host interface used for the network.
          If set to `""` the name is set to `kleened` prefixed with an integer.
          If `type` is set to `custom` the value of `interface` must refer to an existing interface.
          The name must not exceed 15 characters.
          """,
          example: "kleene0",
          default: ""
        },
        subnet: %Schema{
          type: :string,
          description:
            "The IPv4 subnet (in CIDR-format) that is used for the network. If set to `\"\"` no IPv4 subnet is used.",
          example: "10.13.37.0/24",
          default: ""
        },
        subnet6: %Schema{
          type: :string,
          description:
            "The IPv6 subnet (in CIDR-format) that is used for the network. If set to `\"\"` no IPv6 subnet is used.",
          example: "2001:db8:8a2e:370:7334::/64",
          default: ""
        },
        gateway: %Schema{
          type: :string,
          description: """
          Only for bridge networks. The default IPv4 router that is added to 'vnet' containers connecting to bridged networks.
          If set to `""` no gateway is used. If set to `"<auto>"` the first IP of the subnet is added to `interface` and used as gateway.
          """,
          default: "",
          example: "192.168.1.1"
        },
        gateway6: %Schema{
          type: :string,
          description: """
          Only for bridge networks. The default IPv6 router that is added to 'vnet' containers connecting to bridged networks.
          See `gateway` for details.
          """,
          default: "",
          example: "2001:db8:8a2e:370:7334::1"
        },
        nat: %Schema{
          type: :string,
          description: """
          Which interface should be used for NAT'ing outgoing traffic from the network.
          If set to `"<host-gateway>"` the hosts gateway interface is used, if it exists.
          If set to `\"\"` no NAT'ing is configured.
          """,
          default: "<host-gateway>",
          example: "igb0"
        },
        icc: %Schema{
          type: :boolean,
          description:
            "Whether or not to enable connectivity between containers within the same network.",
          default: true
        },
        internal: %Schema{
          type: :boolean,
          description:
            "Whether or not the network is internal, i.e., not allowing outgoing upstream traffic",
          default: false
        },
        external_interfaces: %Schema{
          description: """
          Name of the external interfaces where incoming traffic is redirected from, if ports are being published externally on this network.
          If set to the empty list `[]` Kleened uses the `gateway` interface.
          """,
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["em0", "igb2"]
        }
        # ip_range: %Schema{
        #  type: :string,
        #  description: "",
        #  example: "192.168.1.1/25"
        # },
        # ip_range6: %Schema{
        #  type: :string,
        #  description: "",
        #  example: "2001:db8:8a2e:370:7334:4ef9:/80"
        # }
      },
      required: [:name, :type]
    })
  end

  defmodule Network do
    OpenApiSpex.schema(%{
      description: "summary description of a network",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of the network", type: :string},
        name: %Schema{
          type: :string,
          description: "Name of the network.",
          example: "westnet"
        },
        type: %Schema{
          type: :string,
          description: """
          What kind of network this is.
          Possible values are `bridge`, `loopback`, `custom`, and `host` networks.
          """,
          example: "bridge",
          enum: ["bridge", "loopback", "custom"]
        },
        subnet: %Schema{
          type: :string,
          description: "The IPv4 subnet (in CIDR-format) that is used for the network.",
          example: "10.13.37.0/24"
        },
        subnet6: %Schema{
          type: :string,
          description: "The IPv6 subnet (in CIDR-format) that is used for the network.",
          example: "2001:db8:8a2e:370:7334::/64"
        },
        interface: %Schema{
          type: :string,
          description: """
          Name for the interface that is being used for the network. If set to `""` the name is automatically set to `kleened` prefixed with a integer.
          If the `type` property is set to `custom` the value of `interface` must be the name of an existing interface.
          The name must not exceed 15 characters.
          """,
          example: "kleene0",
          default: ""
        },
        external_interfaces: %Schema{
          description: """
          Name of the external interfaces where incoming traffic is redirected from, if ports are being published externally on this network.
          If an element is set to `"gateway"` the interface of the default router/gateway is used, if it exists.
          """,
          type: :array,
          items: %Schema{type: :string},
          default: ["gateway"],
          example: ["em0", "igb2"]
        },
        gateway: %Schema{
          type: :string,
          description: """
          The default IPv4 router that is added to 'vnet' containers connecting to the network.
          If `""` no gateway is used.
          """,
          default: "",
          example: "192.168.1.1"
        },
        gateway6: %Schema{
          type: :string,
          description: """
          The default IPv6 router that is added to 'vnet' containers connecting to the network.
          If `""` no gateway is used.
          """,
          default: "",
          example: "2001:db8:8a2e:370:7334::1"
        },
        nat: %Schema{
          type: :string,
          description: """
          Which interface should be used for NAT'ing outgoing traffic from the network.
          If set to `\"\"` no NAT'ing is configured.
          """,
          default: "",
          example: "igb0"
        },
        icc: %Schema{
          type: :boolean,
          description:
            "Whether or not to enable connectivity between containers within the network.",
          default: true
        },
        internal: %Schema{
          type: :boolean,
          description:
            "Whether or not the network is internal, i.e., not allowing outgoing upstream traffic",
          default: true
        }
      }
    })
  end

  defmodule EndPointConfig do
    OpenApiSpex.schema(%{
      description: "Configuration of a connection between a network to a container.",
      type: :object,
      properties: %{
        container: %Schema{
          type: :string,
          description: "Identifier of the container using this endpoint."
        },
        network: %Schema{
          type: :string,
          description: "Name of the network that this endpoint belongs to."
        },
        ip_address: %Schema{
          type: :string,
          description:
            "The IPv4 address that should be assigned to the container. If set to `\"<auto>\"` an unused ip from the subnet will be used. If set to `\"\"` no address will be set.",
          default: "",
          example: "10.13.37.33"
        },
        ip_address6: %Schema{
          type: :string,
          description:
            "The IPv6 address that should be assigned to the container. If set to `\"<auto>\"` an unused ip from the subnet will be used. If set to `\"\"` no address will be set.",
          default: "",
          example: "2001:db8:8a2e:370:7334::2"
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
        network_id: %Schema{
          type: :string,
          description: "Name of the network that this endpoint belongs to."
        },
        container_id: %Schema{
          type: :string,
          description: "ID of the container that this endpoint belongs to."
        },
        epair: %Schema{
          description: "epair used for endpoint in case of a VNET network",
          type: :string,
          nullable: true
        },
        ip_address: %Schema{
          type: :string,
          description: "The IPv4 address of the container.",
          default: nil,
          example: "10.13.37.33"
        },
        ip_address6: %Schema{
          type: :string,
          description: "The IPv6 address of the container.",
          default: nil,
          example: "FIXME"
        }
      }
    })
  end

  defmodule PublishedPort do
    OpenApiSpex.schema(%{
      description: "FIXME",
      type: :object,
      properties: %{
        container_id: %Schema{description: "FIXME", type: :string},
        network_id: %Schema{description: "FIXME", type: :string},
        host_ip: %Schema{description: "FIXME", type: :integer},
        host_port: %Schema{description: "FIXME", type: :string},
        container_port: %Schema{description: "FIXME", type: :string},
        protocol: %Schema{description: "FIXME", type: :string, enum: ["tcp", "udp"]},
        internal: %Schema{description: "FIXME", type: :boolean}
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
          There are four methods for creating a new base image:

          - `\"fetch\"`: Fetch a release/snapshot of the base system and use it for image creation.
          - `\"fetch-auto\"`: Automatically fetch a release/snapshot from the offical FreeBSD mirrors, based on information from `uname(1)`.
          - `\"zfs-copy\"`: Create the base image based on a copy of `zfs_dataset`.
          - `\"zfs-clone\"`: Create the base image based on a clone of `zfs_dataset`.
          """,
          type: :string,
          enum: ["fetch", "fetch-auto", "zfs-copy", "zfs-clone"]
        },
        tag: %Schema{
          description: """
          Name and optionally a tag in the `name:tag` format.
          """,
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
          description: """
          ZFS dataset that the image should be based on.
          *Method `\"zfs-*\"` only*.
          """,
          type: :string,
          default: ""
        },
        url: %Schema{
          description: """
          URL to a remote location where the base system (as a base.txz file) is stored.
          *Method `\"fetch\"` only*.
          """,
          type: :string,
          default: ""
        },
        force: %Schema{
          description: """
          Ignore any discrepancies detected when using `uname(1)` to fetch the base system.
          *Method `\"fetch-auto\"` only*.
          """,
          type: :boolean,
          default: false
        },
        autotag: %Schema{
          description: """
          Whether or not to auto-genereate a nametag `FreeBSD-<version>:latest` based on `uname(1)`.
          *Method `\"fetch-auto\"` only*.
          """,
          type: :boolean,
          default: true
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
        cmd: %Schema{
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
        created: %Schema{description: "When the image was created", type: :string},
        dataset: %Schema{description: "ZFS dataset of the image", type: :string}
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

  defmodule Volume do
    OpenApiSpex.schema(%{
      description: "Volume object used for persistent storage in containers.",
      type: :object,
      properties: %{
        name: %Schema{description: "Name of the volume", type: :string},
        dataset: %Schema{description: "ZFS dataset used for the volume", type: :string},
        mountpoint: %Schema{description: "Mountpoint of `dataset`", type: :string},
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

  defmodule MountPointConfig do
    OpenApiSpex.schema(%{
      description: """
      Create a mount point between sthe host file system and a container.

      There are two `type`'s of mount points:

      - `nullfs`: Mount a user-specified file or directory from the host machine into the container.
      - `volume`: Mount a Kleene volume into the container.
      """,
      type: :object,
      properties: %{
        type: %Schema{
          type: :string,
          description: "Kind of mount to create: `nullfs` or `volume`.",
          enum: ["volume", "nullfs"]
        },
        destination: %Schema{
          type: :string,
          description: "Destination path of the mount within the container."
        },
        source: %Schema{
          type: :string,
          description: """
          Source used for the mount. Depends on `method`:

          - If `method="volume"` then `source` should be a volume name
          - If `method="nullfs"`  then `source` should be a (absolute) path on the host
          """
        },
        read_only: %Schema{
          type: :boolean,
          description: "Whether the mountpoint should be read-only.",
          default: false
        }
      }
    })
  end

  defmodule MountPoint do
    OpenApiSpex.schema(%{
      description: """
      Mount point between some part of the host file system and a container.
      There are two types of mountpoints:

      - `nullfs`: Mount from a user-specified file or directory from the host machine into the container.
      - `volume`: Mount from a Kleene volume into the container.
      """,
      type: :object,
      properties: %{
        type: %Schema{
          type: :string,
          description: "Kind of mount: `nullfs` or `volume`.",
          enum: ["volume", "nullfs"]
        },
        container_id: %Schema{
          type: :string,
          description: "ID of the container that the mountpoint belongs to."
        },
        destination: %Schema{
          type: :string,
          description: "Destination path of the mount within the container."
        },
        source: %Schema{
          type: :string,
          description: """
          Source used for the mount. Depends on `method`:

          - If `method="volume"` then `source` should be a volume name
          - If `method="nullfs"`  then `source` should be a (absolute) path on the host
          """
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
        cmd: %Schema{
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
