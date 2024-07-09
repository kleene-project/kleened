PATH = PATH=$$PATH:./priv/bin

package:
	mix release --overwrite

init:
	mix run --eval "Kleened.Core.Config.initialize_host(%{dry_run: false})"

dryinit:
	mix run --eval "Kleened.Core.Config.initialize_host(%{dry_run: true})"

test:
	${PATH} mix test --seed 0 --trace --max-failures 1

shell:
	${PATH} MIX_ENV=test iex -S mix

test-shell:
	MIX_ENV=test mix run -e "Kleened.Test.Utils.create_test_base_image()"
	${PATH} MIX_ENV=test iex -S mix

codecov:
	${PATH} MIX_ENV=test mix coveralls.html -o ./coveralls --max-failures 5

runpty: c_src/runpty.c
	$(CC) -o priv/bin/kleened_pty $(CFLAGS) $(LDFLAGS) $<

clean-runpty:
	rm -rf priv/bin/runpty

.PHONY: test
