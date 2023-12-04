package:
	mix release --overwrite

test:
	mix test --seed 0 --trace --max-failures 1

shell:
	iex -S mix

test-shell:
	MIX_ENV=test mix run -e "Kleened.Test.TestImage.create_test_base_image()"
	MIX_ENV=test iex -S mix

clear-kleened:
	zfs destroy -rf zroot/kleene
	zfs create zroot/kleene
	rm /var/run/kleened.*

codecov:
	MIX_ENV=test mix coveralls.html -o ./coveralls --max-failures 5

runpty: c_src/runpty.c
	$(CC) -o priv/bin/runpty $(CFLAGS) $(LDFLAGS) $<

clean-runpty:
	rm -rf priv/bin/runpty

.PHONY: test
