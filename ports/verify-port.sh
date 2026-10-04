#!/bin/sh
# Verify the vendored sysutils/kleene-daemon port against a FreeBSD ports
# branch, with poudriere. Run as root; the intended entry point is the
# Makefile.vm target 'verify-kleened-port', which calls sudo itself.
#
# Stages:
#   1. Ensure poudriere, its config, two build jails (15.1 and 14.5) and a
#      ports tree cloned from PORTS_BRANCH exist. Idempotent: everything is
#      created only when missing, so reruns reuse jails and cached packages.
#   2. `poudriere testport` the branch's own sysutils/kleene-daemon. On
#      2026Q3 this reproduces the official build failure and is EXPECTED TO
#      FAIL; set EXPECT_REPRO_FAILURE=0 to expect success instead (for
#      branches where the port is not broken).
#   3. Overlay this repository's vendored port onto the tree, `testport` it
#      in both jails, and `bulk`-build the package in the 15.x jail.
#
# Logs and a summary land in RESULTS_DIR (default /tmp/kleene-port-verify),
# which must be VM-local: the script runs as root and cannot write to the
# 9P-shared checkout. When invoked via sudo, results are chowned back to the
# invoking user at the end.
#
# Knobs (environment):
#   PORTS_BRANCH   ports branch to test against     (default 2026Q3)
#   PTREE          poudriere ports tree name        (default quarterly)
#   JAIL151        15.x jail name                   (default port151)
#   JAIL151_VERSION                                 (default 15.1-RELEASE)
#   JAIL145        14.x jail name                   (default port145)
#   JAIL145_VERSION                                 (default 14.5-RELEASE)
#   RESULTS_DIR    where logs/summary are written   (default /tmp/kleene-port-verify)
set -eu

PORTS_BRANCH=${PORTS_BRANCH:-2026Q3}
PTREE=${PTREE:-quarterly}
JAIL151=${JAIL151:-port151}
JAIL151_VERSION=${JAIL151_VERSION:-15.1-RELEASE}
JAIL145=${JAIL145:-port145}
JAIL145_VERSION=${JAIL145_VERSION:-14.5-RELEASE}
RESULTS_DIR=${RESULTS_DIR:-/tmp/kleene-port-verify}
EXPECT_REPRO_FAILURE=${EXPECT_REPRO_FAILURE:-1}

PORT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/sysutils/kleene-daemon
POUDRIERE_BASE=/usr/local/poudriere
CONF=/usr/local/etc/poudriere.conf

[ "$(id -u)" -eq 0 ] || { echo "run as root: 'make verify-kleened-port'" >&2; exit 64; }
[ -d "$PORT_DIR" ] || { echo "cannot find port dir: $PORT_DIR" >&2; exit 66; }

mkdir -p "$RESULTS_DIR"
SUMMARY="$RESULTS_DIR/summary.txt"
: > "$SUMMARY"
say() { echo "$@" | tee -a "$SUMMARY"; }

# --- stage 1: poudriere, config, jails, ports tree -------------------------
pkg info -q poudriere || pkg install -y poudriere

# A conf that is missing, or the package's stock sample (placeholder values
# and no ZPOOL), counts as unconfigured -- the sample is installed by the
# poudriere package itself, so testing for file existence is not enough.
unconfigured() {
    [ ! -f "$CONF" ] && return 0
    ! grep -q '^ZPOOL=' "$CONF"
}

if unconfigured; then
    {
        echo "ZPOOL=zroot"
        echo "BASEFS=$POUDRIERE_BASE"
        echo "DISTFILES_CACHE=/usr/ports/distfiles"
        echo "RESOLV_CONF=/etc/resolv.conf"
        # The default jail-creation host is ftp://; force the https mirror.
        echo "FREEBSD_HOST=https://download.freebsd.org"
    } > "$CONF"
    say "wrote $CONF"
fi
mkdir -p /usr/ports/distfiles

jail_list=$(poudriere jail -l 2>/dev/null | awk '{print $1}')
ports_list=$(poudriere ports -l 2>/dev/null | awk '{print $1}')

echo "$jail_list" | grep -qx "$JAIL151" || poudriere jail -c -j "$JAIL151" -v "$JAIL151_VERSION"
echo "$jail_list" | grep -qx "$JAIL145" || poudriere jail -c -j "$JAIL145" -v "$JAIL145_VERSION"
echo "$ports_list" | grep -qx "$PTREE" || poudriere ports -c -p "$PTREE" -m git+https -B "$PORTS_BRANCH"

# --- stage 2: the branch's own port (the reproduction) ---------------------
say "stage 2: testport the port as it exists on $PORTS_BRANCH"
if poudriere testport -j "$JAIL151" -p "$PTREE" -o sysutils/kleene-daemon \
        > "$RESULTS_DIR/testport-repro.log" 2>&1; then
    repro_rc=0
else
    repro_rc=1
fi
if [ "$repro_rc" -eq 0 ] && [ "$EXPECT_REPRO_FAILURE" -eq 0 ]; then
    say "PASS  the $PORTS_BRANCH port builds (as expected)"
elif [ "$repro_rc" -ne 0 ] && [ "$EXPECT_REPRO_FAILURE" -eq 1 ]; then
    say "PASS  the $PORTS_BRANCH port fails to build (as expected)"
    if grep -q "Could not start Hex" "$RESULTS_DIR/testport-repro.log"; then
        say "      and the failure matches the official builders: 'Could not start Hex'"
    else
        say "WARN  but the log does not mention Hex; check testport-repro.log"
    fi
else
    say "FAIL  unexpected reproduction result (rc=$repro_rc, EXPECT_REPRO_FAILURE=$EXPECT_REPRO_FAILURE)"
    say "      log: $RESULTS_DIR/testport-repro.log"
    exit 1
fi

# --- stage 3: the vendored port (the fix) -----------------------------------
say "stage 3: testport the vendored port overlaid onto $PORTS_BRANCH"
rm -rf "$POUDRIERE_BASE/ports/$PTREE/sysutils/kleene-daemon"
cp -R "$PORT_DIR" "$POUDRIERE_BASE/ports/$PTREE/sysutils/"

for jail in "$JAIL151" "$JAIL145"; do
    if poudriere testport -j "$jail" -p "$PTREE" -o sysutils/kleene-daemon \
            > "$RESULTS_DIR/testport-fixed-$jail.log" 2>&1; then
        say "PASS  testport fixed port in $jail"
    else
        say "FAIL  testport fixed port in $jail; log: $RESULTS_DIR/testport-fixed-$jail.log"
        exit 1
    fi
done

if poudriere bulk -j "$JAIL151" -p "$PTREE" sysutils/kleene-daemon \
        > "$RESULTS_DIR/bulk-fixed.log" 2>&1; then
    pkg_file=$(ls "$POUDRIERE_BASE/data/packages/$JAIL151-$PTREE/All"/kleene-daemon-*.pkg)
    say "PASS  bulk build: $(basename "$pkg_file")"
    cp "$pkg_file" "$RESULTS_DIR/"
else
    say "FAIL  bulk build; log: $RESULTS_DIR/bulk-fixed.log"
    exit 1
fi

say "all stages passed"
if [ -n "${SUDO_USER:-}" ]; then
    chown -R "$SUDO_USER" "$RESULTS_DIR"
fi
