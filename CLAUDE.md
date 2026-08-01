# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Kleened is the backend daemon of **Kleene**, a container management tool for FreeBSD built on
jails, ZFS and pf. It is an Elixir/OTP application exposing a REST + WebSocket API; the
reference client is the `klee` Python CLI, whose HTTP client is generated from this repo's
OpenAPI spec.

When working inside the `kleene_dev` checkout, `../CLAUDE.md` documents the QEMU/libvirt
development VM, the `klee` CLI and the docs site. This file covers the daemon itself.

When implementing new features, remember to adjust the docs site and relevant docs in
the klee and kleened repositories.

## Runtime constraint — read first

Kleened only runs on **FreeBSD**, as **root**. It shells out to `/usr/sbin/jail`, `zfs`,
`pfctl`, `ifconfig` and `mount_nullfs`, so there is no meaningful way to exercise it on Linux
or macOS.

- Runs anywhere: `mix compile`, `mix format`, `mix dialyzer`. The dialyzer workflow
  (`.github/workflows/dialyzer.yml`) deliberately runs on `ubuntu-latest` for this reason.
- Requires a FreeBSD host as root: `mix test`, and anything touching `Core.ZFS`,
  `Core.FreeBSD`, `Core.Network`, `Core.Exec` or `Core.Mount`.

The test suite assumes a prepared host:

- `/usr/local/etc/kleened/config.yaml` (copy `example/kleened_config_dev.yaml`)
- `/usr/local/etc/kleened/pf.conf.kleene` (copy `example/pf.conf.dev.kleene`)
- `/usr/local/etc/kleened/certs/` (copy `test/data/test_certs/`)
- a `zroot/kleene_basejail` dataset holding an extracted FreeBSD `base.txz`
- `mix run --eval "Kleened.Core.Config.initialize_host(%{dry_run: false})"`, run once
- `kldload if_bridge`, `service pf start`, `service pflog start`,
  `sysctl net.link.bridge.pfil_bridge=1` — without the last one some networking tests fail

`.github/workflows/run_tests.yml` is the executable version of that list; consult it rather
than reinventing the setup.

## Commands

All targets live in `Makefile` and must be run as root on the FreeBSD host.

```sh
make test          # mix test --seed 0 --trace --max-failures 1
make shell         # MIX_ENV=test iex -S mix
make test-shell    # same, but creates the FreeBSD:testing base image first
make codecov       # excoveralls HTML report into ./coveralls/
make release       # mix release --overwrite
make init          # Config.initialize_host, for real
make dryinit       # Config.initialize_host, dry run
make runpty        # compile c_src/runpty.c -> priv/bin/kleened_pty
```

Running a single test file or line requires `priv/bin` on `PATH` (see below):

```sh
PATH=$PATH:./priv/bin mix test test/network_test.exs
PATH=$PATH:./priv/bin mix test test/network_test.exs:412
```

**`priv/bin` must be on `PATH` for any test that allocates a TTY.** `Core.OS.cmd_async/2`
locates the `kleened_pty` helper with `:os.find_executable`, not by path. The Makefile's
`PTY_PATH` variable exists for this; note its comment explaining why it is *not* named `PATH`
(GNU make would export it and clobber the real one, so `mix` would no longer be found).

Static analysis:

```sh
make dialyzer-plt  # slow (minutes); only needed once, and again when mix.lock changes
make dialyzer
mix format         # .formatter.exs covers {mix,.formatter}.exs and config/ lib/ test/
```

Regenerating the API spec:

```sh
mix openapi.spec.json --spec Kleened.API.Spec   # writes ./openapi.json (gitignored)
```

## Architecture

### Supervision tree

`lib/core/application.ex` starts, in order: `Core.Config`, `Core.MetaData`, `Core.Network`, a
`Registry` named `Core.ExecInstances`, a `DynamicSupervisor` named `Core.ExecPool`, then one
`Plug.Cowboy` child per configured listening socket. The pool runs with `max_restarts: 0` — a
crashed exec instance is not retried. Once the tree is up, containers whose `restart_policy`
is `"on-startup"` are started.

### Config

`lib/core/config.ex` has two distinct entry points:

- `bootstrap/0` runs *before* the supervision tree and returns the cowboy listener specs
  parsed from `api_listening_sockets`.
- `initialize_host/1` is a separate one-shot host-preparation path (load `zfs`/`pf`/`pflog`
  kmods, set the corresponding `sysrc` entries, create the root dataset, enable `rctl`). It is
  what `make init` and the `kleened init` rc-script command call.

At runtime config is a string-keyed map behind an `Agent` (`Config.get/2`). Several keys are
derived in `initialize/0` and never appear in the YAML: `container_root`, `image_root`,
`volume_root`, `metadata_db`, and `host_gateway` (detected from the routing table).

### MetaData

`lib/core/metadata.ex` is an `Agent` wrapping a SQLite connection (exqlite). Records are
stored as **JSON blobs** in `networks`, `images`, `containers`, `volumes`, `mounts` and
`endpoint_configs`, and queried with SQLite's `json_extract`/`json_insert`. The
`api_list_containers` view joins image name/tag onto each container row.

Rows are decoded back into `Schemas.*` structs by `transform_row/2`, which dispatches on the
query's **column names**. Changing a `SELECT` list therefore silently changes which struct
comes back — keep column names in sync with that function.

### API layer

There are two routers, and only one of them is Plug:

- REST goes through `API.Router` (`Plug.Router`, `lib/api/router.ex`), with one
  `Plug.Builder` submodule per operation (e.g. `API.Container.List`).
- WebSocket endpoints are raw cowboy handlers, registered ahead of the catch-all Plug handler
  in `Router.dispatch/0`: `/exec/start`, `/images/build`, `/images/create`.

**Adding an endpoint touches three places:**

1. the route in `lib/api/router.ex` (or the cowboy dispatch list for a websocket),
2. a module exporting `open_api_operation/1`,
3. a `PathItem` entry in `lib/api/api_spec.ex`.

A route missing from `api_spec.ex` still compiles and serves, but is invisible to the OpenAPI
spec, to `klee`'s generated client, and to the test suite's `assert_schema` checks. Request
and response schemas live in `lib/api/schemas.ex`.

### WebSocket protocol

Described once in `API.Utils.general_websocket_description/0`, which every handler embeds into
its OpenAPI description — update it there, not per endpoint.

The client sends its configuration as the first frame (not as a request body). The server
replies with a `starting` message, then streams raw process output, then closes. Close codes:
`1000` finished normally, `1001` started detached, `1002` invalid config frame, `1011`
execution error or unexpected crash. Every protocol frame is a `Schemas.WebSocketMessage`
(`msg_type` / `message` / `data`); helpers to build them are in `API.Utils`.

### Exec

`lib/core/exec.ex` runs one transient `GenServer` per exec instance, registered by exec id in
`Core.ExecInstances`. It opens a `Port` on `/usr/sbin/jail` via `OS.cmd_async/2` — optionally
wrapped in `kleened_pty` when a TTY is requested — and fans output out to subscribers as
`{:container, exec_id, msg}` messages.

Jail parameters from the container config are merged with defaults by
`update_jailparam_if_not_exist/3`; the networking parameters are produced by
`create_networking_jail_params/1`, which branches on the container's network driver.

### Storage

Images are ZFS datasets at `<kleene_root>/image/<id>` carrying an `@image` snapshot
(`Core.Const.image_snapshot/0`). A container is a `zfs clone` of that snapshot at
`<kleene_root>/container/<id>`. Consequences worth knowing:

- Removing an image means walking clone dependencies first — see `Image.prune/1` and
  `zfs_kleene_clones/1` in `lib/core/image.ex`.
- An image reference may carry a snapshot suffix (`name:tag@snapshot`), split by
  `Core.Utils.decode_snapshot/1`, so a container can be created from an intermediate build
  snapshot rather than the final image.

### Image build and create

`Core.Dockerfile.parse/1` turns a Dockerfile into `{line, instruction}` tuples
(`:from`, `:user`, `:env`, `:arg`, `:workdir`, `:run`, `:cmd`, `:copy`). `Core.Image.build/1`
then drives a `State` machine that executes each instruction inside a scratch container,
taking a ZFS snapshot as it goes, and finally converts the container dataset into an image.
`COPY` is implemented by nullfs-mounting the build context into the container.

`Core.ImageCreate.start_image_creation/1` builds a base image by one of four methods —
`fetch-auto`, `fetch`, `zfs-copy`, `zfs-clone` — reporting progress to the calling process as
`{:image_creator, pid, ...}` messages.

### Networking

`lib/core/network.ex` (~1300 lines) is the densest module. Two orthogonal concepts are easy to
conflate:

- **network type**: `bridge`, `loopback`, `custom` — a property of the network.
- **container network driver**: `host`, `ipnet`, `vnet`, `disabled` — a property of the
  container.

`connect_with_driver/3` implements the matrix of the two.

pf is managed **wholesale, not incrementally**. `configure_pf/0` regenerates the complete
ruleset from MetaData and renders it into the three EEx placeholders of the template at
`pf_config_template_path` (`kleene_macros`, `kleene_translation`, `kleene_filtering` — see
`example/pf.conf.kleene`), writes it to `pf_config_path`, and reloads pf. Published container
ports become `rdr` rules, so publishing a port is a full pf-config regeneration rather than a
per-container operation.

### Shelling out

Everything external goes through `Core.OS.cmd/2`, `OS.shell/2` or `OS.cmd_async/2`
(`lib/core/os.ex`), which centralise logging and the warning on non-zero exit — both
suppressible via the options map. FreeBSD tooling is invoked with `--libxo json` and parsed
with Jason (see `Core.FreeBSD`) rather than screen-scraped.

## Testing

- `test/test_helper.exs` (~950 lines) defines the `TestHelper` module that every test uses.
  REST calls are made in-process with `Plug.Test.conn |> Router.call/2`; WebSocket calls go
  over the **real** unix socket `/var/run/kleened.sock` using `:gun`. The suite therefore needs
  a configured, listening daemon socket even though most calls bypass the network stack.
- `TestHelper.validate_response/3` asserts every response against the OpenAPI spec via
  `assert_schema/3`. An endpoint missing from `api_spec.ex` will fail here.
- `Kleened.Test.ConnCase` (`test/utils/kleene_testcase.ex`) supplies `api_spec` and a
  `host_state` snapshot to each test. `TestHelper.compare_to_baseline_environment/1` asserts
  that interfaces, devfs mounts and ZFS datasets are back to their baseline — a leaked jail or
  mount will fail unrelated tests later in the run.
- A `FreeBSD:testing` base image is cloned from `zroot/kleene_basejail` at suite start by
  `Kleened.Test.Utils.create_test_base_image/0`. Tests must not remove it.
- `--seed 0 --max-failures 1` is deliberate: tests share global host state and are order
  dependent, so the run aborts on the first failure instead of cascading.
- `KLEENED_MINIMAL_TESTJAIL` points at `test/data/minimal_testjail.txz` (gitignored, built by
  the `mkjail` tool) and is used by the `klee` suite.

## Conventions and gotchas

- Public functions carry `@spec`s (swept in `5742a67`); keep new ones typed.
- `config/dialyzer.ignore.exs` is an explicit **debt list, not an allowlist**. `mix.exs` sets
  `list_unused_filters: true`, so a filter that no longer matches fails the run — fixing a
  warning *requires* deleting its entry.
- **`deps/` is committed to the repository** (~800 files) so the FreeBSD port can build with
  `HEX_OFFLINE=true`. Bumping a dependency means re-vendoring `deps/`, not just updating
  `mix.lock`.
- `ports/sysutils/kleene-daemon/` is the FreeBSD port. Its `DISTVERSION` and the `version` in
  `mix.exs` must move together, `distinfo` must match the GitHub tarball, and `pkg-plist`
  tracks the release layout.
- `.tool-versions` (Elixir 1.20.2 / OTP 29) is mirrored by hand in
  `.github/workflows/dialyzer.yml`; keep the two in sync.
- `openapi.json` is gitignored here. The pretty-printed copy consumed by `klee` and the docs
  lives in the parent `kleene_dev` repo as `kleened_openapi.json`.

## In-flight branches

Feature work that is **not on `main`** but that you may be pointed at:

- **`deploy`** — the "deployment" feature (declarative specs covering several resources at
  once). Adds `POST /deployment/diff` and `/deployment/create/{containers,networks,volumes}`
  (`lib/api/deployment.ex`), a `/deployment/build` WebSocket (`lib/api/deployment_build.ex`),
  `Core.Deployment` (create + diff against existing state), and `Core.ImageBulkBuild` — a
  named GenServer that builds many images in parallel, ordering them by a `libgraph` DAG built
  from their `FROM` parents. Pulls in a new dependency, `libgraph`.
  `test/deployment_test.exs` is a placeholder; the real coverage lives in `klee`.
- **`context-upload`** — sits on the same deployment base and adds build-context file upload
  (`lib/api/context.ex`, `Context.Create`).

Both branches are **behind `main` on infrastructure**, not ahead of it: they still carry
`version: "0.1.0"`, the pre-0.1.1 dependency set, and the old `config/dialyzer.ignore` (not
`.exs`), and they predate both the dialyzer CI gate and the typespec sweep. Bringing them
forward means rebasing onto that work, not merging `main` into them wholesale.
