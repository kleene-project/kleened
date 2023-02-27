package:
	mix release --overwrite

test:
	mix test --seed 0 --trace --max-failures 1

shell:
	iex -S mix

clear-kleened:
	zfs destroy -rf zroot/kleene
	zfs create zroot/kleene

codecov:
	MIX_ENV=test mix coveralls.html -o ./coveralls --max-failures 5

runpty: c_src/runpty.c
	$(CC) -o priv/bin/runpty $(CFLAGS) $(LDFLAGS) $<

clean-runpty:
	rm -rf priv/bin/runpty

.PHONY: test
