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
          nullable: true,
          example: [
            "FreeBSD:13.2-STABLE",
            "FreeBSD:13.2-STABLE@6b3c821605d4",
            "48fa55889b0f",
            "48fa55889b0f@2028818d6f06"
          ]
        },
        cmd: %Schema{
          description:
            "Command to execute when the container is started. If `[]` is specified the command from the image is used.",
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
          If user is set to `""`, the user from the image will be used, which in turn is 'root' if no user is specified there.

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
          default: [],
          example: [
            %{
              type: "volume",
              destination: "/mnt/db",
              source: "database"
            },
            %{
              type: "nullfs",
              destination: "/webapp",
              source: "/home/me/develop/webapp"
            }
          ]
        },
        jail_param: %Schema{
          description: """
          List of jail parameters to use for the container.
          See the [jails manual page](https://man.freebsd.org/cgi/man.cgi?query=jail) for an explanation of what jail parameters is,
          and the [Kleene documentation](/run/jail-parameters/) for an explanation of how they are used by Kleene.
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
        },
        public_ports: %Schema{
          description:
            "Listening ports on network interfaces that redirect incoming traffic to the container.",
          type: :array,
          items: Kleened.API.Schemas.PublishedPortConfig,
          nullable: true,
          default: [],
          example: [
            %{
              interfaces: ["em0"],
              host_port: "8080",
              container_port: "8000",
              properties: "tcp"
            }
          ]
        }
      }
    })
  end

  defmodule Container do
    OpenApiSpex.schema(%{
      description: "Kleene container",
      type: :object,
      properties: %{
        id: %Schema{description: "The id of the container", type: :string},
        name: %Schema{description: "Name of the container.", type: :string},
        image_id: %Schema{
          description: "ID of the image that this container was created from",
          type: :string
        },
        cmd: %Schema{
          description: "Command used when starting the container",
          type: :array,
          items: %Schema{type: :string},
          default: []
        },
        user: %Schema{
          description: "Default user used when creating execution instances in the container.",
          type: :string
        },
        env: %Schema{
          description:
            "List of environment variables. The list will be merged with environment variables defined by the image. The values in this list takes precedence if the variable is defined in both.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
        },
        network_driver: %Schema{
          type: :string,
          description: """
          What kind of network driver the container uses.
          Possible values are `ipnet`, `host`, `vnet`, `disabled`.
          """,
          example: "ipnet",
          enum: ["ipnet", "host", "vnet", "disabled"]
        },
        public_ports: %Schema{
          description:
            "Listening ports on network interfaces that redirect incoming traffic to the container.",
          type: :array,
          items: Kleened.API.Schemas.PublishedPort,
          default: [],
          example: [
            %{
              interfaces: ["em0"],
              host_port: "8080",
              container_port: "8000",
              properties: "tcp"
            }
          ]
        },
        jail_param: %Schema{
          description: """
          List of jail parameters to use for the container.
          See the [jails manual page](https://man.freebsd.org/cgi/man.cgi?query=jail) for an explanation of what jail parameters is,
          and the [Kleene documentation](/run/jail-parameters/) for an explanation of how they are used by Kleene.
          """,
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

  defmodule ContainerSummary do
    OpenApiSpex.schema(%{
      description: "Summary description of a container",
      type: :object,
      allOf: [
        Kleened.API.Schemas.Container,
        %Schema{
          type: :object,
          properties: %{
            image_name: %Schema{
              description: "Name of the image that this container was created from",
              type: :string
            },
            image_tag: %Schema{
              description: "Tag of the image that this container was created from",
              type: :string
            },
            running: %Schema{
              description: "Whether or not the container is running",
              type: :boolean
            },
            jid: %Schema{
              description: "Jail ID if it is a running container",
              type: :integer,
              nullable: true
            }
          }
        }
      ]
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

  defmodule ExecConfig do
    OpenApiSpex.schema(%{
      description:
        "Configuration of an executable to run within a container. Some of the configuration parameters will overwrite the corresponding parameters if they are defined in the container.",
      type: :object,
      properties: %{
        container_id: %Schema{
          type: :string,
          description: "Identifier of the container used as environemnt for the exec instance."
        },
        cmd: %Schema{
          description:
            "Command to execute whithin the container. If `cmd` is set to `[]` the command will be inherited from the container.",
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["/bin/sh", "-c", "ls /"]
        },
        user: %Schema{
          type: :string,
          description:
            "User that executes the command in the container. If the user is set to `\"\"`, the user will be inherited from the container.",
          default: ""
        },
        env: %Schema{
          description: """
          A list of environment variables in the form `["VAR=value", ...]` that is set when the command is executed.
          This list will be merged with environment variables defined in the container.
          The values in this list takes precedence if the variable is defined in both.
          """,
          type: :array,
          items: %Schema{type: :string},
          default: [],
          example: ["DEBUG=0", "LANG=da_DK.UTF-8"]
        },
        tty: %Schema{
          description: "Allocate a pseudo-TTY for the process.",
          type: :boolean,
          default: false
        }
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
          description: "ID of the execution instance to start"
        },
        attach: %Schema{
          description: "Whether to receive output from `stdin` and `stderr`.",
          type: :boolean
        },
        start_container: %Schema{
          type: :boolean,
          description: "Whether to start the container if it is not already running."
        }
      },
      required: [:exec_id, :attach, :start_container]
    })
  end

  defmodule ImageBuildConfig do
    OpenApiSpex.schema(%{
      description:
        "Configuration for an image build, including container configuration for the build container.",
      type: :object,
      properties: %{
        context: %Schema{
          type: :string,
          description:
            "Location path on the Kleened host of the context used for the image build."
        },
        dockerfile: %Schema{
          type: :string,
          description:
            "Path of the Dockerfile used for the build. The path is relative to the context path.",
          default: "Dockerfile"
        },
        quiet: %Schema{
          type: :boolean,
          description:
            "Whether or not to send status messages of the build process to the client.",
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
            "A name and optional tag to apply to the image in the `name:tag` format. If `tag` is omitted, the default value `latest` is used.",
          default: ""
        },
        buildargs: %Schema{
          description: """
          Additional `ARG`-variables given as an object of string pairs.
          See the [`ARG` instruction documentation](/reference/dockerfile/#arg) for details.
          """,
          type: :object,
          default: %{},
          example: %{"USERNAME" => "Stephen", "JAIL_MGMT_ENGINE" => "kleene"}
        },
        container_config: %OpenApiSpex.Reference{"$ref": "#/components/schemas/ContainerConfig"},
        networks: %Schema{
          description:
            "List of endpoint-configs for the networks that the build container will be connected to.",
          type: :array,
          items: Kleened.API.Schemas.EndPointConfig,
          default: []
        }
      },
      required: [:context, :container_config]
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

          - `fetch`: Fetch a release/snapshot of the base system from `url` and use it for image creation.
          - `fetch-auto`: Automatically fetch a release/snapshot from the offical FreeBSD mirrors, based on information from `uname(1)`.
          - `zfs-copy`: Create the base image based on a copy of `zfs_dataset`.
          - `zfs-clone`: Create the base image based on a clone of `zfs_dataset`.
          """,
          type: :string,
          enum: ["fetch", "fetch-auto", "zfs-copy", "zfs-clone"]
        },
        tag: %Schema{
          description: """
          Name and optionally a tag in the `name:tag` format. If `tag` is omitted, the default value `latest` is used.
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
          **`zfs-*` methods only**

          ZFS dataset that the image should be based on.
          """,
          type: :string,
          default: ""
        },
        url: %Schema{
          description: """
          **`fetch` method only**

          URL to the base system (a `base.txz` file) that Kleened should use to create the base image.
          """,
          type: :string,
          default: ""
        },
        force: %Schema{
          description: """
          **`fetch-auto` method only**

          Ignore any discrepancies in the output of `uname(1)` when determining the FreeBSD version.
          """,
          type: :boolean,
          default: false
        },
        autotag: %Schema{
          description: """
          **`fetch-auto` method only**

          Whether or not to auto-genereate a nametag `FreeBSD-<version>:latest` based on `uname(1)`.
          Overrides `tag` if set to `true`.
          """,
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
        user: %Schema{description: "User used for running `cmd`", type: :string},
        instructions: %Schema{
          description: """
          Instructions and their corresponding snapshots (if they exist) that were used to build the image.
          Each item in the array consists of a 2-element array `["<instruction>","<snapshot>"]`
          containing one instruction and possibly its snapshot.
          The latter is only be present with `RUN` or `COPY` instructions that ran succesfully.
          Otherwise `<snapshot>` is empty.
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
          description: "What kind of network should be created.",
          example: "bridge",
          enum: ["bridge", "loopback", "custom"]
        },
        interface: %Schema{
          type: :string,
          description: """
          Name of the host interface used for the network.
          If set to `""` the name is set to `kleened` postfixed with an integer.
          If `type` is set to `custom` the value of `interface` must refer to an existing interface,
          otherwise it is created by Kleened.
          """,
          maxLength: 15,
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
          **`bridge` networks only**

          The default (IPv4) router that is added to `vnet` containers connecting to bridged networks.
          If set to `""` no gateway is used. If set to `"<auto>"` the first IP of the subnet is added to `interface` and used as gateway.
          """,
          default: "",
          example: "192.168.1.1"
        },
        gateway6: %Schema{
          type: :string,
          description: """
          **`bridge` networks only**

          The default IPv6 router that is added to `vnet` containers connecting to bridged networks.
          See `gateway` for details.
          """,
          default: "",
          example: "2001:db8:8a2e:370:7334::1"
        },
        nat: %Schema{
          type: :string,
          description: """
          Interface used for NAT'ing outgoing traffic from the network.
          If set to `"<host-gateway>"` the hosts gateway interface is used, if it exists.
          If set to `\"\"` no NAT'ing is configured.
          """,
          default: "<host-gateway>",
          example: "igb0"
        },
        icc: %Schema{
          type: :boolean,
          description:
            "Inter-container connectvity: Whether or not to enable connectivity between containers within the same network.",
          default: true
        },
        internal: %Schema{
          type: :boolean,
          description: "Whether or not outgoing traffic is allowed on the network.",
          default: false
        }
      },
      required: [:name, :type]
    })
  end

  defmodule Network do
    OpenApiSpex.schema(%{
      description: "Kleene network",
      type: :object,
      properties: %{
        id: %Schema{description: "ID of the network", type: :string},
        name: %Schema{
          type: :string,
          description: "Name of the network.",
          example: "westnet"
        },
        type: %Schema{
          type: :string,
          description: "Network type.",
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
          Name for the interface that is being used for the network.
          """,
          maxLength: 15,
          example: "kleene0",
          default: ""
        },
        gateway: %Schema{
          type: :string,
          description: """
          The default IPv4 router that is added to `vnet` containers connecting to the network.
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
            "Inter-container connectvity: Whether or not to enable connectivity between containers within the network.",
          default: true
        },
        internal: %Schema{
          type: :boolean,
          description: "Whether or not outgoing traffic is allowed on the network.",
          default: true
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
      description: "Detailed information on a network.",
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

  defmodule EndPointConfig do
    OpenApiSpex.schema(%{
      description: "Configuration of a connection between a network to a container.",
      type: :object,
      properties: %{
        container: %Schema{
          type: :string,
          description:
            "Container identifier, i.e., the name, ID, or an initial unique segment of the ID."
        },
        network: %Schema{
          type: :string,
          description:
            "Network identifier, i.e., the name, ID, or an initial unique segment of the ID."
        },
        ip_address: %Schema{
          type: :string,
          description:
            "IPv4 address for the container. If set to `\"<auto>\"` an unused ip from the subnet will be used. If set to `\"\"` no address will be set.",
          default: "",
          example: "10.13.37.33"
        },
        ip_address6: %Schema{
          type: :string,
          description:
            "IPv6 address for the container. If set to `\"<auto>\"` an unused ip from the subnet will be used. If set to `\"\"` no address will be set.",
          default: "",
          example: "2001:db8:8a2e:370:7334::2"
        }
      },
      required: [:container, :network]
    })
  end

  defmodule EndPoint do
    OpenApiSpex.schema(%{
      description: "Endpoint connecting a container to a network.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Endpoint ID"},
        network_id: %Schema{
          type: :string,
          description: "Name of the network that this endpoint belongs to."
        },
        container_id: %Schema{
          type: :string,
          description: "ID of the container that this endpoint belongs to."
        },
        epair: %Schema{
          description: """
          **`vnet` containers only**

          `epair(4)` interfaces connecting the container to the network.
          """,
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
          example: "2610:1c1:1:606c::50:15"
        }
      }
    })
  end

  defmodule PublishedPortConfig do
    OpenApiSpex.schema(%{
      description: "Configuration for publishing a port of a container.",
      type: :object,
      properties: %{
        interfaces: %Schema{
          description: """
          List of host interfaces where the port is published, i.e.,
          where traffic to `host_port` is redirected to `container_port` (on a random IP-address).
          If set to `[]` the host's gateway interface is used.
          """,
          type: :array,
          items: %Schema{type: :string},
          default: []
        },
        host_port: %Schema{
          description: """
          Source port (or portrange) on the host where incoming traffic is redirected.

          `host_port` can take one of two forms:
          - A single portnumber `"PORTNUMBER"`
          - A portrange `"PORTNUMBER_START:PORTNUMBER_END"`
          """,
          type: :string
        },
        container_port: %Schema{
          description: """
          Destination port (or portrange) of the container that accepts traffic from `host_port`.

          `container_port` can take two forms, depending on `host_port`:
          - A single portnumber `"PORTNUMBER"` if `host_port` is a single port number
          - A portrange `"PORTNUMBER_START:*"` if `host_port` is a port range
          """,
          type: :string
        },
        protocol: %Schema{
          description: "Whether to use TCP or UDP as transport protocol",
          type: :string,
          enum: ["tcp", "udp"],
          default: "tcp"
        }
      },
      required: [:interfaces, :host_port, :container_port]
    })
  end

  defmodule PublishedPort do
    OpenApiSpex.schema(%{
      description:
        "A published port of a container, i.e., opening up the port for incoming traffic from external sources.",
      type: :object,
      properties: %{
        interfaces: %Schema{
          description: """
          List of host interfaces where incoming traffic to `host_port` is redirected to the container at `ip_address` and/or `ip_address6` on `container_port`.
          """,
          type: :array,
          items: %Schema{type: :string},
          default: []
        },
        host_port: %Schema{
          description: """
          Source port (or portrange) on the host where incoming traffic is redirected.

          `host_port` can take one of two forms:
          - A single portnumber `"PORTNUMBER"`
          - A portrange `"PORTNUMBER_START:PORTNUMBER_END"`
          """,
          type: :string
        },
        container_port: %Schema{
          description: """
          Destination port (or portrange) of the container that accepts traffic from `host_port`.

          `container_port` can take two forms, depending on `host_port`:
          - A single portnumber `"PORTNUMBER"` if `host_port` is a single port number
          - A portrange `"PORTNUMBER_START:*"` if `host_port` is a port range
          """,
          type: :string
        },
        protocol: %Schema{description: "tcp or udp", type: :string, enum: ["tcp", "udp"]},
        ip_address: %Schema{
          description:
            "ipv4 address within the container that receives traffic to `container_port`",
          type: :string
        },
        ip_address6: %Schema{
          description:
            "ipv6 address within the container that receives traffic to `container_port`",
          type: :string
        }
      },
      required: [:interfaces, :host_port, :container_port, :protocol, :ip_address, :ip_address6]
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

  defmodule Volume do
    OpenApiSpex.schema(%{
      description: "Volume object used for persistent storage in containers.",
      type: :object,
      properties: %{
        name: %Schema{description: "Name of the volume", type: :string},
        dataset: %Schema{description: "ZFS dataset of the volume", type: :string},
        mountpoint: %Schema{description: "Mountpoint of `dataset`", type: :string},
        created: %Schema{description: "When the volume was created", type: :string}
      }
    })
  end

  defmodule MountPointConfig do
    OpenApiSpex.schema(%{
      description: """
      Configuration for a mount point between the host file system and a container.

      There are two types of mount points:

      - `nullfs`: Mount a user-specified file or directory from the host machine into the container.
      - `volume`: Mount a Kleene volume into the container.
      """,
      type: :object,
      properties: %{
        type: %Schema{
          type: :string,
          description: "Type of mountpoint to create.",
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

          - If `method` is `"volume"` then `source` should be a volume name
          - If `method`is `"nullfs"` then `source` should be an absolute path on the host
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
      Mount point between the host file system and a container.

      There are two types of mount points:

      - `nullfs`: Mount a user-specified file or directory from the host machine into the container.
      - `volume`: Mount a Kleene volume into the container.
      """,
      type: :object,
      properties: %{
        type: %Schema{
          type: :string,
          description: "Mounpoint type.",
          enum: ["volume", "nullfs"]
        },
        container_id: %Schema{
          type: :string,
          description: "ID of the container that the mountpoint belongs to."
        },
        destination: %Schema{
          type: :string,
          description: "Destination path of the mountpoint within the container."
        },
        source: %Schema{
          type: :string,
          description: """
          Source used for the mount. Depends on `method`:

          - If `method` is `"volume"` then `source` should be a volume name
          - If `method`is `"nullfs"` then `source` should be an absolute path on the host
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

  defmodule WebSocketMessage do
    OpenApiSpex.schema(%{
      description: "Protocol messages sent from Kleened's websocket endpoints",
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
            "Any data that might have been created by the process such as an image ID.",
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
          description: "ID of the created/modified/removed object.",
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
