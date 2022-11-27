package:
	mix release --overwrite

test:
	mix test --seed 0 --trace --max-failures 1

shell:
	iex -S mix

clear-jocker:
	zfs destroy -rf zroot/jocker
	zfs create zroot/jocker

codecov:
	MIX_ENV=test mix coveralls.html -o ./coveralls --max-failures 5

.PHONY: test
