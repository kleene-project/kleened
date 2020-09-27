package:
	mix release --overwrite
	mix escript.build

test:
	mix escript.build
	mix test --seed 1 --trace --max-failures 1


.PHONY: test
