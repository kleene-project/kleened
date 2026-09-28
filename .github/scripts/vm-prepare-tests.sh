#!/bin/sh
# Baked into the cached VM image (cache-after-prepare). Invoked as a one-liner
# from both run_tests.yml and build_and_test_package.yml so they hash identical
# prepare text and share the image cache. When changing what this script leaves
# in the image, bump the '# vN' comment at both call sites -- the cache key
# hashes the one-line prepare text only.
#
# Installs the toolchain superset for both workflows, provides the zroot pool,
# the basejail dataset, and the minimal test-jail tarball. Everything that must
# survive a cache-hit reboot lives outside $GITHUB_WORKSPACE (the action wipes
# and re-syncs the workspace on every boot); /root does.
set -eu

FREEBSD_VERSION=15.1-RELEASE

pkg install -y elixir erlang gmake ca_root_nss git ruby python py312-poetry

###### ZFS ######
kldload zfs 2>/dev/null || true
sysrc -f /boot/loader.conf zfs_load="YES"
sysrc zfs_enable="YES"
# The 15.1 anyvm image boots from a ZFS pool already named 'zroot' (its boot
# disk is a sparse 206 GiB qcow2, so there is ample room for the kleene datasets
# on it). Older images booted from UFS and needed a dedicated pool created
# here. kleened/klee hardcode zroot/... dataset paths, so the pool must be
# named 'zroot' either way.
if ! zpool list -H -o name zroot >/dev/null 2>&1; then
  truncate -s 20G /home/runner/zpool.disk
  zpool create -O atime=off -f zroot /home/runner/zpool.disk
fi

###### Basejail (userland must match the 15.1 kernel) ######
zfs list zroot/kleene_basejail >/dev/null 2>&1 || zfs create zroot/kleene_basejail
fetch "https://download.freebsd.org/releases/amd64/${FREEBSD_VERSION}/base.txz"
tar -xf base.txz -C /zroot/kleene_basejail
rm -f base.txz

###### Minimal test-jail (used by the klee suite) ######
mkdir -p /root/kleened-ci
[ -f /root/kleened-ci/minimal_testjail.txz ] || {
  git clone --depth 1 https://github.com/kleene-project/mkjail.git /root/kleened-ci/mkjail
  # mkjail's last arguments are a smoke test it runs inside the built jail; no
  # klee test executes python in there, so /bin/sh suffices (and py311 does not
  # exist on 15.1).
  /root/kleened-ci/mkjail/mkjail -a /root/kleened-ci/minimal_testjail.txz /bin/sh -c 'echo ok'
}
