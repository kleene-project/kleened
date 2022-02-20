package:
	mix release --overwrite

test:
	mix escript.build
	mix test --seed 1 --trace --max-failures 1

clear-jocker:
	zfs destroy -rf zroot/jocker
	zfs create zroot/jocker

.PHONY: test
