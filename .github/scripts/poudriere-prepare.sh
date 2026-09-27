#!/bin/sh
# Baked into the cached VM image (cache-after-prepare) for the package-build
# workflow. Installs poudriere, creates the zroot pool, two build jails
# (14.5-RELEASE and 15.1-RELEASE) and the ports tree. When changing what this
# script leaves in the image, bump the '# vN' comment at the call site -- the
# cache key hashes the one-line prepare text only.
#
# Everything lives on the 20G zpool: two poudriere jails plus the ports tree
# plus distfiles do not fit on 10G.
set -eu

pkg install -y poudriere git

kldload zfs 2>/dev/null || true
sysrc -f /boot/loader.conf zfs_load="YES"
sysrc zfs_enable="YES"
truncate -s 20G /home/runner/zpool.disk
zpool create -O atime=off -f zroot /home/runner/zpool.disk

{
  echo "ZPOOL=zroot"
  echo "BASEFS=/usr/local/poudriere"
  echo "DISTFILES_CACHE=/usr/ports/distfiles"
  echo "RESOLV_CONF=/etc/resolv.conf"
  # Default jail-creation method is ftp://; force the https mirror.
  echo "FREEBSD_HOST=https://download.freebsd.org"
} > /usr/local/etc/poudriere.conf

mkdir -p /usr/ports/distfiles

poudriere jail -c -j pkg145 -v 14.5-RELEASE
poudriere jail -c -j pkg151 -v 15.1-RELEASE

# poudriere's git method clones with --depth=1 by default.
poudriere ports -c -p development -m git+https -B main
