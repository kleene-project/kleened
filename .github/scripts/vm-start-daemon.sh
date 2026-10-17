#!/bin/sh
# Build the kleened release and start the daemon in the background, waiting for
# its socket before returning. The klee suite talks to a running daemon over
# /var/run/kleened.sock; without the wait, the suite races daemon startup.
set -eu
cd "$GITHUB_WORKSPACE"

mix release --overwrite
ln -sf "$GITHUB_WORKSPACE/priv/bin/kleened_pty" /usr/local/sbin/kleened_pty

_build/dev/rel/kleened/bin/kleened daemon

n=0
until sockstat -l | grep -q /var/run/kleened.sock; do
  n=$((n + 1))
  if [ "$n" -gt 60 ]; then
    echo "kleened did not listen on /var/run/kleened.sock within 60s"
    tail -50 /var/log/kleened.log
    exit 1
  fi
  sleep 1
done
echo "kleened is listening on /var/run/kleened.sock"
