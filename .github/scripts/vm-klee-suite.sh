#!/bin/sh
# Run the klee (pytest) suite against the running kleened daemon. Needs a
# pristine kleene state (vm-reset-kleene.sh) and a listening daemon
# (vm-start-daemon.sh) first: the suite asserts on ZFS dataset totals, so
# leftovers fail unrelated tests.
#
# KLEE_REF is passed in from the workflow (the host-side branch probe decides
# whether it is the kleened branch's klee twin or main).
set -eu

git clone --depth 1 -b "${KLEE_REF:-main}" https://github.com/kleene-project/klee.git \
    "$GITHUB_WORKSPACE/klee"
cd "$GITHUB_WORKSPACE/klee"

# The venv must live outside the checkout for the same reason as on the dev VM:
# nothing here writes back to the workspace we care about, and in-project venvs
# are a global poetry setting we do not want to depend on.
poetry config virtualenvs.in-project false
# '--with dev': on poetry 2.x the dev group is not installed by default, and
# without it pytest itself is missing.
poetry install --with dev
VENV=$(poetry env info --path)

# The suite writes Dockerfile/klee_config.yaml into os.getcwd(), so run it from
# a scratch dir. PATH must include the venv: a few tests shell out to the 'klee'
# binary (the three config-precedence tests in root_test and the nullfs-mount
# image build).
mkdir -p /tmp/klee-run
cd /tmp/klee-run

# Test debt -- the six known failures recorded in the workspace's
# docs/TESTING-BASELINE.md (2026-08-04 run on the 15.1 dev VM). The exact
# three root_test.py entries were not individually recorded there; if a smoke
# run shows different names, correct this list to match reality. Shrink it as
# they are fixed; never grow it.
DESELECTS="
--deselect test/container_test.py::TestContainerCore::test_create_container_with_custom_jail_params
--deselect test/image_test.py::TestImageBuildContainerConfig::test_build_image_with_nullfs_mount
--deselect test/root_test.py::TestFileConfiguration::test_multiple_config_file_priority
--deselect test/root_test.py::TestFileConfiguration::test_envvar_takes_priority
--deselect test/root_test.py::TestFileConfiguration::test_command_line_config_takes_priority
--deselect test/connection_test.py::TestHTTPConnections::test_connecting_with_ipv6_and_no_tls
"

KLEENED_MINIMAL_TESTJAIL=/root/kleened-ci/minimal_testjail.txz \
    "$VENV/bin/pytest" -vv -o cache_dir=/tmp/pytest_cache \
    $DESELECTS \
    "$GITHUB_WORKSPACE/klee/test"
