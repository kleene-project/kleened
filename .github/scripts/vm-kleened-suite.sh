#!/bin/sh
# Run the kleened (ExUnit) suite. Needs the host prepared by vm-reset-kleene.sh
# and kleened compiled (mix compile runs the :run_pty compiler, which builds
# priv/bin/kleened_pty).
set -eu
cd "$GITHUB_WORKSPACE"

mix local.rebar --force
mix local.hex --force
mix compile
mix run --eval "Kleened.Core.Config.initialize_host(%{dry_run: false})"

# 'kleened_pty' must be on PATH: Core.OS.cmd_async/2 locates it with
# :os.find_executable, not by path, so any test that allocates a TTY needs it.
PATH="$PATH:$GITHUB_WORKSPACE/priv/bin"
export PATH

mix test --seed 0 --trace --max-failures 1
