package:
	mix release --overwrite

test:
	mix test --seed 0 --trace --max-failures 1

clear-jocker:
	zfs destroy -rf zroot/jocker
	zfs create zroot/jocker

.PHONY: test
