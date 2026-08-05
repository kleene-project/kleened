# Prefix for targets that need the compiled 'kleened_pty' helper on PATH.
# NB: do not name this variable PATH -- GNU make exports it and the recipes
# then lose the real PATH, so 'mix' cannot be found.
PTY_PATH = PATH=$$PATH:./priv/bin

release:
	mix release --overwrite

init:
	mix run --eval "Kleened.Core.Config.initialize_host(%{dry_run: false})"

dryinit:
	mix run --eval "Kleened.Core.Config.initialize_host(%{dry_run: true})"

test:
	${PTY_PATH} mix test --seed 0 --trace --max-failures 1

# The fast tier: tests tagged :unit, which are pure functions over their inputs.
# '--no-start' keeps the OTP application down, so no config file, ZFS pool, pf or
# daemon socket is needed. test_helper.exs skips creating the base image when it
# sees the run is unit-only.
test-unit:
	mix test --no-start --only unit

shell:
	${PTY_PATH} MIX_ENV=test iex -S mix

test-shell:
	MIX_ENV=test mix run -e "Kleened.Test.Utils.create_test_base_image()"
	${PTY_PATH} MIX_ENV=test iex -S mix

codecov:
	${PTY_PATH} MIX_ENV=test mix coveralls.html -o ./coveralls --max-failures 5

# Build the persistent lookup table. Slow (minutes), but only needed once and
# whenever mix.lock changes.
dialyzer-plt:
	mix dialyzer --plt

dialyzer:
	mix dialyzer

# The rule is on the built file, not on the 'runpty' alias. Naming the target
# 'runpty' meant no such file ever existed, so make rebuilt the helper on *every*
# invocation -- and mix.exs registers a :run_pty compiler that calls this on every
# 'mix compile'. In the dev VM the repo is a 9P share that root cannot write to, so
# a root-side compile truncated priv/bin/kleened_pty and then failed, leaving no
# helper at all and every jail-based test failing with exit-code 8.
# NB: the source is named literally rather than via '$<'. BSD make (FreeBSD's
# make) only defines '$<' for inference rules, so in an explicit rule it expands
# to nothing and the compile fails with "no input files".
priv/bin/kleened_pty: c_src/runpty.c
	mkdir -p priv/bin
	$(CC) -o $@ $(CFLAGS) $(LDFLAGS) c_src/runpty.c

runpty: priv/bin/kleened_pty

clean-runpty:
	rm -f priv/bin/kleened_pty

.PHONY: test dialyzer dialyzer-plt runpty clean-runpty
