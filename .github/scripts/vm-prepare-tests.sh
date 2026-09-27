#!/bin/sh
# Baked into the cached VM image (cache-after-prepare). Invoked as a one-liner
# from both run_tests.yml and build_and_test_package.yml so they hash identical
# prepare text and share the image cache. When changing what this script leaves
# in the image, bump the '# vN' comment at both call sites -- the cache key
# hashes the one-line prepare text only.
#
# Installs the toolchain superset for both workflows, creates the zroot pool,
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
truncate -s 20G /home/runner/zpool.disk
zpool create -O atime=off -f zroot /home/runner/zpool.disk

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
