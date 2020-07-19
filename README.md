# Jocker - Docker-like container management in FreeBSD
Jocker is an attempt to create a Docker-inspired tool for containerization
and container management that is using the native FreeBSD tooling such as jails and ZFS.
Thus, the same abstractions and building blocks that is used by Docker is replicated in Jocker, such as
Dockerfiles, images, containers, and so on, with the whole thing being powered by jails and ZFS under the hood.

## Development status
*Jocker is still in a very early stage of development and should only be used for development purposes and playing around for fun and giggles.*
Hopefully a stable version containing basic functionalities to be used for minor non-critical infrastructure can be released in the foreseeable future.
No promises, though! :-)

## General design principles
To get a better understanding of the distinction between Docker and Jocker, there are a few guiding principles behind the current development that
might be interesting to know:

  * **Docker-inspired**: Besides the basic concepts of container, image, etc., there are several other similarities:
    * **Similar client interface**: The command names and options have by and large been adopted directly from the Docker CLI.
    It is not a strict requirement, however, and new commands made exclusively for Jocker might be implemented in the future.

    * **client/server architecture**: Just like Docker there is seperation between a backend daemon (Jocker Engine) and a client (Jocker Client) that communicates with the backend. At the moment there are tight couplings between client/server so use client on the same machine as the server for now.
    
    * **Dockerfiles to build images**: Most of the possible instructions from Dockerfiles are understood by Jocker and can be used when building images. Jocker-specific instructions might be implemented in the future.
    Note that this is not an attempt to make a FreeBSD version resembling Docker as much as possible. Deviations in CLI and backend have already been made and more will happen in the future when the basics are in place and further development can evolve in more independent directions.

  * **Reproducibility**: At the moment there is no plans for implementing a component similar to the Docker-registry. While Dockerfiles should be shared, the immediate goal of Jocker is to support a build-it-yourself approach to Dockerfiles and images, so there is no direct functionality for sharing images. Instead, build the images from scratch on the specific release of FreeBSD that you use (may that be -RELEASE, -STABLE or -CURRENT branches) including fetching the newest versions of packages or building the newest versions of the ports.
  * **Concurrency-oriented development**: Jocker is developed in Elixir which is based on Erlang and as such runs on the Erlang VM (BEAM). Erlang, in turn,
  is designed for building scalable, concurrent and distributed systems and this design is inherited by Elixir.
  This means that Jocker is already being designed for concurrency and running in parallel on multicore systems.
  But more importantly, using Elixir as the implementation language paves the way for extending Jocker into the world of distributed computing and applying the OTP-principles in container management.

## Why make Jocker?
First of all: Because it's fun! :)
Secondly: The author has been a happy user of FreeBSD for many years and besides being (imho) a structured, well-documented OS with
the power to serve, the OS-level virtualisation implementation of FreeBSD [jails](https://www.freebsd.org/doc/handbook/jails.html)
have also been an integral part of the joy of working with FreeBSD..

However, when observing the containerization movement that is going on in the Linux-world, it seems like we are
missing out. Docker and the vast ecosystem that exists around it have been rushing forward at
a rapid pace, with new features, ideas, and technology being developed constantly. All backed by lots of
experience running production environments, at scale. Sure, we have great tools for managing jails (
such as ezjail, BastilleBSD, pot, iocage, etc.) and some of them have been around for a long time, but they all seem to be thin wrappers around
the basic jail tools which (imho!) comes short of the much more structured and comprehensive approach to containerization
that comes with Docker. Perhaps it is time to try and absorb the ideas of the 'Docker-movement' while giving it a BSD-flavour,
and thus the Jocker-project was born. 

Needless to say, there is a place for both approaches to jails, i.e., comprehensive container management vs. lightweight jail utilities.
Ezjail in particular have served the author well through the years (thanks for the awesome tool, Dirk!).

Another tool with similiar (but not identical goal) to Jocker is [Focker](https://github.com/sadaszewski/focker), which is a lightweight tool
for container management with a lesser compatability goal compared to Jocker, but with a similar overall Docker-inspired approach. Check it out!
 


# Installation guide
Since Jocker is still in an stage of development, the installation is done more or less manually.
It does not require any knowledge of FreeBSD except basic familiarity with unix/linux
operating systems. However, a few references to the FreeBSD Handbook is made and if you are new to FreeBSD
it is highly recommended to take dive into some of the chapters (perhaps on how to install FreeBSD in the first place?).

## Creating a "base" image
Firstly, you need to prepare your FreeBSD installation by making a seperate userland for the images & containers. This will act similarily to a [base image](https://docs.docker.com/glossary/#base_image)
in Docker: When building images in Jocker, the `FROM scratch` instruction in a Dockerfile will use the jail-userland that is built following these steps as the base image.
Section 14.3.1. in the FreeBSD handbook describes the different ways to [initialize a new userland](https://www.freebsd.org/doc/handbook/jails-build.html) which
can be used for jails (remember, containers in Jocker is just FreeBSD jails).
The `/here/is/the/jail` path mentioned in the handbook should be a mountpoint of a zfs dataset since Jocker relies on zfs snapshotting & clones when building the
image and container hierachy. In these installtion instructions `/here/is/the/jail` is set to `zroot/jocker_basejail` since this the default in the jocker configuration file (see below).

**Note**: If the environment is build from source you should not mount devfs filesystem in the last step of section 14.3.3.

**Note**: It is recommended to keep the kernel and userland version in sync to avoid instability and unpredictable errors.

## Installing Jocker
Start by installing the dependencies used for fetching and building Jocker:

```
$ sudo pkg install elixir elixir-hex git-lite
```

then create the basic datasets that is used by jocker

```
$ sudo zfs create zroot/jocker         # root dataset where images and containers are stored
$ sudo zfs create zroot/jocker/volumes # where jocker creates its volumes
```

and then fetch sources and build the Jocker cli tool and daemon, including deps

```
$ git clone https://github.com/lgandersen/jocker
$ cd jocker
$ mix deps.get
$ mix local.rebar # required by esqlite3, installs local Jocker-specific copy
$ mix release
$ mix escript.build
```

## Configure and try Jocker
Start by copying the sample configuration file into `/usr/local/etc/`

```
$ sudo cp ./example/jocker_config.yaml /usr/local/etc/
$ sudo ee /usr/local/etc/jocker_config.yaml # do some editing, if necessary
```

in this guide we have used the default values so no editing is necessary
otherwise make the necessary adjustments. Now we are ready to take jocker for
a spin. Open a new terminal and start the jocker-engine daemon:

```
# Assuming you are back into your cloned jocker git-repository folder
$ sudo _build/dev/rel/jocker/bin/jocker start
```

and then try the cli tool in a different terminal and follow the documentation
that comes with it

```
$ ./jocker

Usage:  jocker [OPTIONS] COMMAND

A self-sufficient runtime for containers

Options:
-v, --version            Print version information and quit

Management Commands:
container   Manage containers
image       Manage images
volume      Manage volumes

Run 'jocker COMMAND --help' for more information on a command.
```
