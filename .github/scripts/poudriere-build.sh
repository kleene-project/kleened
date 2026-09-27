#!/bin/sh
# Build the kleene-daemon pkg in both poudriere jails and copy the results into
# pkg_out/ in the workspace, from where the action's copyback delivers them to
# the runner. Do not try to write $GITHUB_OUTPUT/$GITHUB_ENV from inside the
# VM -- they do not propagate; the copyback is the transport.
set -eu
cd "$GITHUB_WORKSPACE"

rm -rf pkg_out
mkdir pkg_out

# The ports tree persists in the cached image, the port itself does not.
rm -rf /usr/local/poudriere/ports/development/sysutils/kleene-daemon
cp -r ports/sysutils/kleene-daemon /usr/local/poudriere/ports/development/sysutils/

# Port QA once; the bulk builds below cover both ABI majors.
poudriere testport -j pkg151 -p development -o sysutils/kleene-daemon

for jail in pkg145 pkg151; do
  # -c removes any previously cached packages, which the prepared image may
  # still carry from an earlier run of this script.
  poudriere bulk -c -j "$jail" -p development sysutils/kleene-daemon
  f=$(ls /usr/local/poudriere/data/packages/${jail}-development/All/kleene-daemon-*.pkg)
  ver=$(basename "$f" | sed -e 's/^kleene-daemon-//' -e 's/\.pkg$//')
  if [ "$jail" = pkg145 ]; then major=14; else major=15; fi
  cp "$f" "pkg_out/kleened-${ver}-freebsd${major}-amd64.pkg"
done

ls -lh pkg_out/
