#!/bin/sh
# Reset kleened to a pristine state and (re)install its host config. Run at the
# start of a CI run and again between the kleened and klee suites: the klee
# suite asserts on ZFS dataset totals, so anything left behind by the previous
# suite fails unrelated tests. Destroying the datasets also drops kleened's
# SQLite metadata, which lives inside zroot/kleene.
set -eu
cd "$GITHUB_WORKSPACE"

# Leftover jails keep their datasets busy, so they must go first.
for jid in $(jls jid 2>/dev/null); do jail -r "$jid" 2>/dev/null || true; done

if zfs list zroot/kleene >/dev/null 2>&1; then
  zfs destroy -rf zroot/kleene
fi
zfs create zroot/kleene
zfs create zroot/kleene/container
zfs create zroot/kleene/image
zfs create zroot/kleene/volumes

rm -f /var/run/kleened.sock /var/run/kleened.tlssock /var/run/kleened.pid

mkdir -p /usr/local/etc/kleened
# NB: 'rm -rf', not 'rm -f' -- 'certs' may be a real directory from an earlier
# run, and rm -f fails on directories, silently landing the copy inside it as
# certs/test_certs instead.
rm -rf /usr/local/etc/kleened/config.yaml /usr/local/etc/kleened/certs
cp example/kleened_config_dev.yaml /usr/local/etc/kleened/config.yaml
cp -r test/data/test_certs /usr/local/etc/kleened/certs
cp example/pf.conf.dev.kleene /usr/local/etc/kleened/pf.conf.kleene

kldload if_bridge 2>/dev/null || true
service pf start 2>/dev/null || true
service pflog start 2>/dev/null || true
# Without this, some networking tests fail (notably the icc=false isolation
# check in network_test.exs).
sysctl net.link.bridge.pfil_bridge=1
