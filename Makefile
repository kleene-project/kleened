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

runpty: c_src/runpty.c
	$(CC) -o priv/bin/kleened_pty $(CFLAGS) $(LDFLAGS) $<

clean-runpty:
	rm -rf priv/bin/runpty

.PHONY: test dialyzer dialyzer-plt
