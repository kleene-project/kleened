# kleene-ports

FreeBSD ports of Kleened: `sysutils/kleene-daemon` (this repo) and
`sysutils/kleene-cli` (the `klee` repo). The vendored port directory is the
source of truth for port updates submitted to FreeBSD Bugzilla — ports HEAD
should always match it.

## Verifying the vendored port

`verify-port.sh` verifies the vendored `sysutils/kleene-daemon` port against
a FreeBSD ports branch with poudriere, mirroring what the official package
builders do. From the dev VM (see the parent workspace):

```sh
make -f Makefile.vm verify-kleened-port                     # vs 2026Q3
PORTS_BRANCH=main EXPECT_REPRO_FAILURE=0 \
    make -f Makefile.vm verify-kleened-port                 # vs HEAD
```

It creates (idempotently) two build jails — 15.1 and 14.5 — and a ports tree
cloned from `PORTS_BRANCH`, then:

1. `poudriere testport`s the port as it exists on that branch (on 2026Q3 this
   reproduces the official build failure; `EXPECT_REPRO_FAILURE` controls
   which outcome is considered a pass),
2. overlays the vendored port onto the tree and `testport`s it in both jails,
3. `poudriere bulk`s the package.

Logs land in `/tmp/kleene-port-verify/` (VM-local; the script runs as root
and cannot write to a 9P-shared checkout).

## History

- 2026-10: the 2026Q3 quarterly branch built 0.1.0-rc.5 with the
  Elixir-1.16-era Hex 2.1.1 archive, which cannot load under the branch's
  OTP 28 (`beam_load.c: op bs_add`). The fix (update to 0.1.1 + Hex
  2.5.1-otp-28 from `installs/1.19.0/`) had already landed on ports HEAD
  (commit 3e6c2d7aba, PR 296849) but was never merged to the quarterly.
  `verify-port.sh` was written to verify the fix before submitting the
  quarterly update to Bugzilla; see the workspace `bugzilla-submission.md`
  and `docs/port-logs/` for logs and the submitted patch.
