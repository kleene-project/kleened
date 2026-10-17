#!/bin/sh
# Dump state for debugging a failed CI run. Run with if: failure() while the
# FreeBSD VM is still up.
set -eu
echo "=== jails ==="; jls || true
echo "=== zfs ==="; zfs list -r zroot/kleene || true
echo "=== listeners ==="; sockstat -l | grep kleened || true
echo "=== kleened log (tail) ==="; tail -80 /var/log/kleened.log || true
echo "=== dmesg (tail) ==="; dmesg | tail -30 || true
